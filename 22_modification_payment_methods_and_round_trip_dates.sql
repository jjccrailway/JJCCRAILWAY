-- JJCC Railways: modification payment methods and round-trip date support.
-- Run AFTER 08_combined_booking_modifications.sql and 13_jcoins_ticket_payment.sql.
-- This migration does not alter the standard ticket-payment workflow.

BEGIN;

ALTER TABLE public.booking_change_requests
  ADD COLUMN IF NOT EXISTS total_amount_due numeric(10,2),
  ADD COLUMN IF NOT EXISTS payment_method text,
  ADD COLUMN IF NOT EXISTS jcoins_amount numeric(10,2) NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS cash_amount numeric(10,2);

ALTER TABLE public.booking_change_requests
  DROP CONSTRAINT IF EXISTS booking_change_requests_amount_due_check;
ALTER TABLE public.booking_change_requests
  ADD CONSTRAINT booking_change_requests_amount_due_check CHECK (amount_due >= 0);

ALTER TABLE public.booking_change_payment_submissions
  ADD COLUMN IF NOT EXISTS payment_method text,
  ADD COLUMN IF NOT EXISTS jcoins_amount numeric(10,2) NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS cash_amount numeric(10,2);

UPDATE public.booking_change_requests
   SET total_amount_due = COALESCE(total_amount_due, amount_due),
       cash_amount = COALESCE(cash_amount, amount_due)
 WHERE total_amount_due IS NULL OR cash_amount IS NULL;

CREATE OR REPLACE FUNCTION public.set_booking_change_payment_method(
  p_request_id bigint,
  p_payment_method text,
  p_jcoins_amount numeric DEFAULT 0
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, auth AS $$
DECLARE
  v_user uuid := auth.uid();
  v_req public.booking_change_requests%ROWTYPE;
  v_wallet public.jcoins_wallets%ROWTYPE;
  v_method text := lower(COALESCE(p_payment_method,''));
  v_total numeric(10,2);
  v_coins numeric(10,2);
  v_cash numeric(10,2);
  v_submission_id bigint;
BEGIN
  IF v_user IS NULL THEN RAISE EXCEPTION 'Please sign in first.'; END IF;
  IF v_method NOT IN ('cash','jcoins','mixed') THEN RAISE EXCEPTION 'Invalid payment method.'; END IF;

  SELECT * INTO v_req FROM public.booking_change_requests
   WHERE request_id=p_request_id AND user_id=v_user FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Modification request not found.'; END IF;
  IF v_req.status NOT IN ('pending_payment','rejected') THEN
    RAISE EXCEPTION 'This modification request is no longer accepting a payment method.';
  END IF;
  IF v_req.payment_deadline_at <= now() THEN RAISE EXCEPTION 'The 10-minute payment window has expired.'; END IF;

  v_total := round(COALESCE(v_req.total_amount_due,v_req.amount_due),2);
  v_coins := round(COALESCE(p_jcoins_amount,0),2);
  IF v_coins < 0 OR v_coins > v_total THEN RAISE EXCEPTION 'Invalid JCoins amount.'; END IF;
  IF v_method='cash' AND v_coins<>0 THEN RAISE EXCEPTION 'Cash-only payment cannot use JCoins.'; END IF;
  IF v_method='jcoins' AND v_coins<>v_total THEN RAISE EXCEPTION 'JCoins-only payment must cover the full amount.'; END IF;
  IF v_method='mixed' AND (v_coins<=0 OR v_coins>=v_total) THEN
    RAISE EXCEPTION 'JCoins + Cash requires a partial JCoins amount.';
  END IF;

  IF v_req.payment_method IS NOT NULL THEN
    IF v_req.payment_method=v_method AND v_req.jcoins_amount=v_coins THEN
      RETURN jsonb_build_object('success',true,'payment_method',v_method,
        'jcoins_amount',v_coins,'cash_amount',COALESCE(v_req.cash_amount,v_req.amount_due),
        'total_amount_due',v_total,'reused',true);
    END IF;
    RAISE EXCEPTION 'A payment method has already been confirmed for this modification request.';
  END IF;

  v_cash := round(v_total-v_coins,2);
  IF v_coins>0 THEN
    SELECT * INTO v_wallet FROM public.jcoins_wallets WHERE user_id=v_user FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'JCoins wallet not found.'; END IF;
    IF v_wallet.balance<v_coins THEN RAISE EXCEPTION 'Insufficient JCoins balance.'; END IF;

    UPDATE public.jcoins_wallets
       SET balance=balance-v_coins,total_spent=total_spent+v_coins,updated_at=now()
     WHERE user_id=v_user RETURNING * INTO v_wallet;

    INSERT INTO public.jcoins_transactions
      (user_id,transaction_type,direction,amount,balance_after,booking_id,booking_reference,
       description,idempotency_key,created_by)
    VALUES
      (v_user,'BOOKING_PAYMENT','debit',v_coins,v_wallet.balance,v_req.booking_id,v_req.booking_reference,
       'Booking modification payment using JCoins',
       'booking-change-payment-'||v_req.request_id::text||'-'||gen_random_uuid()::text,v_user);
  END IF;

  UPDATE public.booking_change_requests
     SET total_amount_due=v_total,payment_method=v_method,jcoins_amount=v_coins,
         cash_amount=v_cash,amount_due=v_cash,updated_at=now()
   WHERE request_id=v_req.request_id;

  IF v_cash=0 THEN
    INSERT INTO public.booking_change_payment_submissions
      (request_id,booking_id,user_id,receipt_path,amount_due,status,payment_method,jcoins_amount,cash_amount)
    VALUES
      (v_req.request_id,v_req.booking_id,v_user,'JCOINS_PAYMENT:'||v_req.request_id::text,
       0,'pending_review','jcoins',v_coins,0)
    RETURNING submission_id INTO v_submission_id;

    UPDATE public.booking_change_requests
       SET status='pending_review',submitted_at=now(),updated_at=now()
     WHERE request_id=v_req.request_id;
  END IF;

  RETURN jsonb_build_object('success',true,'payment_method',v_method,
    'jcoins_amount',v_coins,'cash_amount',v_cash,'total_amount_due',v_total,
    'status',CASE WHEN v_cash=0 THEN 'pending_review' ELSE 'pending_payment' END,
    'submission_id',v_submission_id,'reused',false);
END;
$$;

-- Replace the receipt RPC so mixed payments retain the split-payment audit details.
CREATE OR REPLACE FUNCTION public.submit_booking_change_receipt(
  p_request_id bigint,
  p_receipt_path text
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, auth AS $$
DECLARE
  v_user uuid := auth.uid();
  v_request public.booking_change_requests%ROWTYPE;
  v_submission_id bigint;
BEGIN
  IF v_user IS NULL THEN RAISE EXCEPTION 'Please sign in first.'; END IF;
  IF COALESCE(btrim(p_receipt_path),'')='' THEN RAISE EXCEPTION 'Receipt path is required.'; END IF;
  IF split_part(p_receipt_path,'/',1)<>v_user::text THEN RAISE EXCEPTION 'Receipt path must belong to your signed-in account.'; END IF;

  SELECT * INTO v_request FROM public.booking_change_requests
   WHERE request_id=p_request_id AND user_id=v_user FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Modification request not found.'; END IF;
  IF v_request.status NOT IN ('pending_payment','rejected') THEN RAISE EXCEPTION 'This modification request is not accepting a receipt.'; END IF;
  IF v_request.payment_deadline_at<=now() THEN
    UPDATE public.booking_change_requests SET status='expired',updated_at=now() WHERE request_id=v_request.request_id;
    RAISE EXCEPTION 'The 10-minute modification payment deadline has expired.';
  END IF;
  IF v_request.payment_method IS NULL OR COALESCE(v_request.cash_amount,v_request.amount_due)<=0 THEN
    RAISE EXCEPTION 'Confirm a cash or split payment method before uploading a receipt.';
  END IF;
  IF EXISTS(SELECT 1 FROM public.booking_change_payment_submissions
             WHERE request_id=v_request.request_id AND status='pending_review') THEN
    RAISE EXCEPTION 'A receipt is already awaiting administrator review.';
  END IF;

  INSERT INTO public.booking_change_payment_submissions
    (request_id,booking_id,user_id,receipt_path,amount_due,status,payment_method,jcoins_amount,cash_amount)
  VALUES
    (v_request.request_id,v_request.booking_id,v_user,p_receipt_path,
     COALESCE(v_request.cash_amount,v_request.amount_due),'pending_review',
     v_request.payment_method,COALESCE(v_request.jcoins_amount,0),COALESCE(v_request.cash_amount,v_request.amount_due))
  RETURNING submission_id INTO v_submission_id;

  UPDATE public.booking_change_requests
     SET status='pending_review',submitted_at=now(),updated_at=now()
   WHERE request_id=v_request.request_id;

  RETURN jsonb_build_object('success',true,'submission_id',v_submission_id,'status','pending_review');
END;
$$;

-- Return JCoins automatically if a mixed-payment receipt is rejected.
CREATE OR REPLACE FUNCTION public.restore_booking_change_jcoins_on_rejection()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE v_wallet public.jcoins_wallets%ROWTYPE; v_req public.booking_change_requests%ROWTYPE;
BEGIN
  IF NEW.status='rejected' AND OLD.status IS DISTINCT FROM 'rejected'
     AND COALESCE(NEW.jcoins_amount,0)>0 THEN
    SELECT * INTO v_req FROM public.booking_change_requests WHERE request_id=NEW.request_id;
    SELECT * INTO v_wallet FROM public.jcoins_wallets WHERE user_id=NEW.user_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'JCoins wallet not found for payment reversal.'; END IF;

    UPDATE public.jcoins_wallets
       SET balance=balance+NEW.jcoins_amount,
           total_spent=GREATEST(0,total_spent-NEW.jcoins_amount),updated_at=now()
     WHERE user_id=NEW.user_id RETURNING * INTO v_wallet;

    INSERT INTO public.jcoins_transactions
      (user_id,transaction_type,direction,amount,balance_after,booking_id,booking_reference,
       description,idempotency_key,created_by)
    VALUES
      (NEW.user_id,'BOOKING_PAYMENT_REVERSAL','credit',NEW.jcoins_amount,v_wallet.balance,
       NEW.booking_id,v_req.booking_reference,'JCoins returned after a rejected modification receipt',
       'booking-change-reversal-'||NEW.submission_id::text,NEW.user_id)
    ON CONFLICT(idempotency_key) DO NOTHING;

    UPDATE public.booking_change_requests
       SET payment_method=NULL,jcoins_amount=0,cash_amount=total_amount_due,
           amount_due=total_amount_due,updated_at=now()
     WHERE request_id=NEW.request_id;
  END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS trg_restore_booking_change_jcoins ON public.booking_change_payment_submissions;
CREATE TRIGGER trg_restore_booking_change_jcoins
AFTER UPDATE OF status ON public.booking_change_payment_submissions
FOR EACH ROW EXECUTE FUNCTION public.restore_booking_change_jcoins_on_rejection();


-- Return a split-payment JCoins debit if the unpaid cash portion expires or is cancelled.
CREATE OR REPLACE FUNCTION public.restore_booking_change_jcoins_on_unpaid_close()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE v_wallet public.jcoins_wallets%ROWTYPE;
BEGIN
  IF NEW.status IN ('expired','cancelled')
     AND OLD.status IS DISTINCT FROM NEW.status
     AND COALESCE(NEW.jcoins_amount,0)>0 THEN
    SELECT * INTO v_wallet FROM public.jcoins_wallets WHERE user_id=NEW.user_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'JCoins wallet not found for payment reversal.'; END IF;
    UPDATE public.jcoins_wallets
       SET balance=balance+NEW.jcoins_amount,
           total_spent=GREATEST(0,total_spent-NEW.jcoins_amount),updated_at=now()
     WHERE user_id=NEW.user_id RETURNING * INTO v_wallet;
    INSERT INTO public.jcoins_transactions
      (user_id,transaction_type,direction,amount,balance_after,booking_id,booking_reference,
       description,idempotency_key,created_by)
    VALUES
      (NEW.user_id,'BOOKING_PAYMENT_REVERSAL','credit',NEW.jcoins_amount,v_wallet.balance,
       NEW.booking_id,NEW.booking_reference,'JCoins returned because the modification cash payment was not completed',
       'booking-change-close-reversal-'||NEW.request_id::text,NEW.user_id)
    ON CONFLICT(idempotency_key) DO NOTHING;
    UPDATE public.booking_change_requests
       SET jcoins_amount=0,payment_method=NULL,cash_amount=total_amount_due,
           amount_due=total_amount_due,updated_at=now()
     WHERE request_id=NEW.request_id;
  END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS trg_restore_booking_change_jcoins_on_close ON public.booking_change_requests;
CREATE TRIGGER trg_restore_booking_change_jcoins_on_close
AFTER UPDATE OF status ON public.booking_change_requests
FOR EACH ROW EXECUTE FUNCTION public.restore_booking_change_jcoins_on_unpaid_close();

-- Keep the return date in sync with the approved combined request.
CREATE OR REPLACE FUNCTION public.apply_booking_change_return_date()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE v_return_date date;
BEGIN
  IF NEW.status='approved' AND OLD.status IS DISTINCT FROM 'approved'
     AND NULLIF(NEW.requested_changes->>'return_travel_date','') IS NOT NULL THEN
    v_return_date := (NEW.requested_changes->>'return_travel_date')::date;
    UPDATE public.bookings
       SET return_travel_date=v_return_date
     WHERE booking_id=NEW.booking_id;
  END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS trg_apply_booking_change_return_date ON public.booking_change_requests;
CREATE TRIGGER trg_apply_booking_change_return_date
AFTER UPDATE OF status ON public.booking_change_requests
FOR EACH ROW EXECUTE FUNCTION public.apply_booking_change_return_date();

CREATE OR REPLACE FUNCTION public.validate_booking_change_round_trip_dates()
RETURNS trigger LANGUAGE plpgsql SET search_path=public AS $$
DECLARE v_outbound date; v_return date;
BEGIN
  v_outbound:=NULLIF(NEW.requested_changes->>'travel_date','')::date;
  v_return:=NULLIF(NEW.requested_changes->>'return_travel_date','')::date;
  IF v_return IS NOT NULL AND (v_outbound IS NULL OR v_return<=v_outbound) THEN
    RAISE EXCEPTION 'Return date must be after the new outbound travel date.';
  END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS trg_validate_booking_change_round_trip_dates ON public.booking_change_requests;
CREATE TRIGGER trg_validate_booking_change_round_trip_dates
BEFORE INSERT OR UPDATE OF requested_changes ON public.booking_change_requests
FOR EACH ROW EXECUTE FUNCTION public.validate_booking_change_round_trip_dates();

REVOKE ALL ON FUNCTION public.set_booking_change_payment_method(bigint,text,numeric) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.set_booking_change_payment_method(bigint,text,numeric) TO authenticated;
REVOKE ALL ON FUNCTION public.submit_booking_change_receipt(bigint,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.submit_booking_change_receipt(bigint,text) TO authenticated;

COMMIT;

-- JJCC Railways | PR 13 - JCoins, cash, and split ticket payments
-- Run AFTER migrations 01, 04, and 09. Back up the database first.
-- 1 JCoin = PHP 1.00. Wallet changes are performed only by this SECURITY DEFINER RPC.

BEGIN;

ALTER TABLE public.payment_submissions
  ADD COLUMN IF NOT EXISTS payment_method text,
  ADD COLUMN IF NOT EXISTS jcoins_amount numeric(10,2) NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS cash_amount numeric(10,2);

ALTER TABLE public.booking_payments
  ADD COLUMN IF NOT EXISTS payment_method text,
  ADD COLUMN IF NOT EXISTS jcoins_amount numeric(10,2) NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS cash_amount numeric(10,2);

ALTER TABLE public.booking_payments
  DROP CONSTRAINT IF EXISTS booking_payments_payment_method_check;
ALTER TABLE public.booking_payments
  ADD CONSTRAINT booking_payments_payment_method_check
  CHECK (payment_method IS NULL OR payment_method IN ('jcoins','cash','mixed'));

COMMENT ON COLUMN public.booking_payments.jcoins_amount IS 'JCoins deducted for this ticket payment; 1 JCoin = PHP 1.00.';
COMMENT ON COLUMN public.booking_payments.cash_amount IS 'Cash portion that must be verified by receipt review.';
COMMENT ON COLUMN public.payment_submissions.cash_amount IS 'Cash amount shown to administrators for receipt verification.';

-- Preserve the original fare snapshot while also recording the exact amount
-- that the administrator must verify for a split payment.
CREATE OR REPLACE FUNCTION public.set_payment_submission_snapshot()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_reference text;
  v_fare numeric(10,2);
  v_date date;
  v_payment public.booking_payments%ROWTYPE;
BEGIN
  SELECT b.booking_reference, b.total_fare, b.travel_date
    INTO v_reference, v_fare, v_date
    FROM public.bookings b
   WHERE b.booking_id = NEW.booking_id AND b.user_id = NEW.user_id;
  IF v_reference IS NULL THEN RAISE EXCEPTION 'Booking not found for this account.'; END IF;
  SELECT * INTO v_payment FROM public.booking_payments
   WHERE booking_id = NEW.booking_id
   ORDER BY created_at DESC, payment_id DESC LIMIT 1;
  NEW.booking_reference := v_reference;
  NEW.total_fare := v_fare;
  NEW.travel_date := v_date;
  NEW.payment_method := COALESCE(v_payment.payment_method, 'cash');
  NEW.jcoins_amount := COALESCE(v_payment.jcoins_amount, 0);
  NEW.cash_amount := COALESCE(v_payment.cash_amount, v_fare);
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public.confirm_booking_jcoins_payment(
  p_booking_reference text,
  p_jcoins_amount numeric,
  p_payment_method text
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_booking public.bookings%ROWTYPE;
  v_wallet public.jcoins_wallets%ROWTYPE;
  v_fare numeric(10,2);
  v_coins numeric(10,2);
  v_cash numeric(10,2);
  v_existing public.booking_payments%ROWTYPE;
  v_method text := lower(COALESCE(p_payment_method,''));
BEGIN
  IF v_user_id IS NULL THEN RAISE EXCEPTION 'Please sign in before paying.'; END IF;
  IF v_method NOT IN ('jcoins','cash','mixed') THEN RAISE EXCEPTION 'Invalid payment method.'; END IF;
  IF p_jcoins_amount IS NULL OR p_jcoins_amount < 0 THEN RAISE EXCEPTION 'Invalid JCoins amount.'; END IF;

  SELECT * INTO v_booking
    FROM public.bookings
   WHERE booking_reference = upper(btrim(p_booking_reference))
     AND user_id = v_user_id
   FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Booking not found for this account.'; END IF;
  IF v_booking.booking_status <> 'pending_payment' THEN
    RAISE EXCEPTION 'This booking is not awaiting payment.';
  END IF;
  IF v_booking.payment_deadline_at IS NULL OR v_booking.payment_deadline_at <= now() THEN
    RAISE EXCEPTION 'The payment deadline has expired.';
  END IF;

  v_fare := round(v_booking.total_fare::numeric, 2);
  v_coins := round(p_jcoins_amount, 2);
  IF v_method = 'cash' AND v_coins <> 0 THEN RAISE EXCEPTION 'Cash-only payment cannot use JCoins.'; END IF;
  IF v_method = 'jcoins' AND v_coins <> v_fare THEN RAISE EXCEPTION 'Full JCoins payment must cover the complete fare.'; END IF;
  IF v_method = 'mixed' AND (v_coins <= 0 OR v_coins >= v_fare) THEN
    RAISE EXCEPTION 'Split payment must use some, but not all, of the ticket fare in JCoins.';
  END IF;
  IF v_coins > v_fare THEN RAISE EXCEPTION 'JCoins cannot exceed the ticket fare.'; END IF;
  v_cash := v_fare - v_coins;

  -- A retry after a lost network response must never debit the wallet twice.
  SELECT * INTO v_existing FROM public.booking_payments
   WHERE booking_id = v_booking.booking_id
   ORDER BY created_at DESC, payment_id DESC LIMIT 1 FOR UPDATE;
  IF FOUND AND v_existing.payment_method IS NOT NULL THEN
    IF v_existing.payment_method = v_method
       AND v_existing.jcoins_amount = v_coins
       AND COALESCE(v_existing.cash_amount,0) = v_cash THEN
      RETURN jsonb_build_object('success', true, 'reused', true,
        'payment_method', v_method, 'jcoins_amount', v_coins, 'cash_amount', v_cash,
        'booking_status', v_booking.booking_status);
    END IF;
    RAISE EXCEPTION 'A payment method has already been confirmed for this booking.';
  END IF;

  IF v_coins > 0 THEN
    SELECT * INTO v_wallet FROM public.jcoins_wallets WHERE user_id = v_user_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'JCoins wallet not found.'; END IF;
    IF v_wallet.balance < v_coins THEN RAISE EXCEPTION 'Insufficient JCoins balance. Your current balance is %.', v_wallet.balance; END IF;

    UPDATE public.jcoins_wallets
       SET balance = balance - v_coins,
           total_spent = total_spent + v_coins,
           updated_at = now()
     WHERE user_id = v_user_id
     RETURNING * INTO v_wallet;

    INSERT INTO public.jcoins_transactions
      (user_id, transaction_type, direction, amount, balance_after,
       booking_id, booking_reference, description, idempotency_key, created_by)
    VALUES
      (v_user_id, 'BOOKING_PAYMENT', 'debit', v_coins, v_wallet.balance,
       v_booking.booking_id, v_booking.booking_reference,
       'Ticket payment using JCoins',
       'booking-payment-' || v_booking.booking_id::text, v_user_id);
  END IF;

  INSERT INTO public.booking_payments
    (booking_id, user_id, provider, amount, currency, payment_status,
     completed_at, updated_at, payment_method, jcoins_amount, cash_amount)
  VALUES
    (v_booking.booking_id, v_user_id,
     CASE WHEN v_method = 'jcoins' THEN 'jcoins' ELSE 'manual_receipt' END,
     v_cash, 'PHP', CASE WHEN v_cash = 0 THEN 'completed' ELSE 'created' END,
     CASE WHEN v_cash = 0 THEN now() ELSE NULL END, now(),
     v_method, v_coins, v_cash);

  IF v_cash = 0 THEN
    UPDATE public.bookings SET booking_status = 'confirmed', paid_at = COALESCE(paid_at, now())
     WHERE booking_id = v_booking.booking_id;
    INSERT INTO public.user_notifications(user_id, booking_id, title, message, notification_type)
    VALUES (v_user_id, v_booking.booking_id, 'JCoins payment successful',
      'Your ticket was fully paid using JCoins. Booking ' || v_booking.booking_reference || ' is confirmed.', 'success');
  END IF;

  RETURN jsonb_build_object('success', true, 'reused', false,
    'payment_method', v_method, 'jcoins_amount', v_coins, 'cash_amount', v_cash,
    'booking_status', CASE WHEN v_cash = 0 THEN 'confirmed' ELSE 'pending_payment' END);
END;
$$;

REVOKE ALL ON FUNCTION public.confirm_booking_jcoins_payment(text,numeric,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.confirm_booking_jcoins_payment(text,numeric,text) TO authenticated;

-- Existing receipt approval code records the original full fare. Normalize the completed
-- payment record to the actual cash portion (the JCoins portion is separately ledgered).
CREATE OR REPLACE FUNCTION public.normalize_completed_cash_payment()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NEW.payment_status = 'completed' AND NEW.cash_amount IS NOT NULL
     AND NEW.amount IS DISTINCT FROM NEW.cash_amount THEN
    UPDATE public.booking_payments
       SET amount = NEW.cash_amount, updated_at = now()
     WHERE payment_id = NEW.payment_id;
  END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS trg_normalize_completed_cash_payment ON public.booking_payments;
CREATE TRIGGER trg_normalize_completed_cash_payment
AFTER UPDATE OF payment_status ON public.booking_payments
FOR EACH ROW EXECUTE FUNCTION public.normalize_completed_cash_payment();

-- If a mixed-payment receipt is rejected, reverse its earlier JCoins debit exactly once.
-- The passenger may then resubmit a receipt for the full fare as a cash-only payment.
CREATE OR REPLACE FUNCTION public.reverse_jcoins_when_cash_receipt_rejected()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_payment public.booking_payments%ROWTYPE;
  v_wallet public.jcoins_wallets%ROWTYPE;
  v_amount numeric(10,2);
BEGIN
  IF NEW.status = 'rejected' AND OLD.status IS DISTINCT FROM 'rejected' THEN
    SELECT * INTO v_payment FROM public.booking_payments
     WHERE booking_id = NEW.booking_id
     ORDER BY created_at DESC, payment_id DESC LIMIT 1 FOR UPDATE;
    IF FOUND AND COALESCE(v_payment.jcoins_amount,0) > 0 THEN
      v_amount := v_payment.jcoins_amount;
      SELECT * INTO v_wallet FROM public.jcoins_wallets WHERE user_id = NEW.user_id FOR UPDATE;
      IF NOT FOUND THEN RAISE EXCEPTION 'Cannot reverse JCoins: wallet not found.'; END IF;

      UPDATE public.jcoins_wallets
         SET balance = balance + v_amount,
             total_spent = GREATEST(0, total_spent - v_amount),
             updated_at = now()
       WHERE user_id = NEW.user_id
       RETURNING * INTO v_wallet;

      INSERT INTO public.jcoins_transactions
        (user_id, transaction_type, direction, amount, balance_after,
         booking_id, booking_reference, description, idempotency_key, created_by)
      SELECT NEW.user_id, 'BOOKING_PAYMENT_REVERSAL', 'credit', v_amount, v_wallet.balance,
             NEW.booking_id, b.booking_reference,
             'JCoins returned because the cash receipt was rejected',
             'payment-reversal-submission-' || NEW.submission_id::text, NEW.user_id
        FROM public.bookings b WHERE b.booking_id = NEW.booking_id
      ON CONFLICT (idempotency_key) DO NOTHING;

      UPDATE public.booking_payments
         SET payment_method = 'cash', jcoins_amount = 0,
             cash_amount = (SELECT total_fare FROM public.bookings WHERE booking_id = NEW.booking_id),
             amount = (SELECT total_fare FROM public.bookings WHERE booking_id = NEW.booking_id),
             provider = 'manual_receipt', payment_status = 'created',
             completed_at = NULL, updated_at = now()
       WHERE payment_id = v_payment.payment_id;
    END IF;
  END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS trg_reverse_jcoins_on_receipt_rejection ON public.payment_submissions;
CREATE TRIGGER trg_reverse_jcoins_on_receipt_rejection
AFTER UPDATE OF status ON public.payment_submissions
FOR EACH ROW EXECUTE FUNCTION public.reverse_jcoins_when_cash_receipt_rejected();

-- Return the JCoins portion if a mixed-payment booking expires before a receipt
-- is submitted. A pending receipt review prevents expiry in migration 04.
CREATE OR REPLACE FUNCTION public.restore_jcoins_on_unpaid_booking_expiry()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_payment public.booking_payments%ROWTYPE;
  v_wallet public.jcoins_wallets%ROWTYPE;
  v_amount numeric(10,2);
BEGIN
  IF NEW.booking_status = 'expired' AND OLD.booking_status IS DISTINCT FROM 'expired' THEN
    SELECT * INTO v_payment FROM public.booking_payments
     WHERE booking_id = NEW.booking_id
     ORDER BY created_at DESC, payment_id DESC LIMIT 1 FOR UPDATE;
    IF FOUND AND COALESCE(v_payment.jcoins_amount,0) > 0
       AND v_payment.payment_status <> 'completed' THEN
      v_amount := v_payment.jcoins_amount;
      SELECT * INTO v_wallet FROM public.jcoins_wallets WHERE user_id = v_payment.user_id FOR UPDATE;
      IF NOT FOUND THEN RAISE EXCEPTION 'Cannot restore expired booking JCoins: wallet not found.'; END IF;

      UPDATE public.jcoins_wallets
         SET balance = balance + v_amount,
             total_spent = GREATEST(0, total_spent - v_amount),
             updated_at = now()
       WHERE user_id = v_payment.user_id
       RETURNING * INTO v_wallet;

      INSERT INTO public.jcoins_transactions
        (user_id, transaction_type, direction, amount, balance_after,
         booking_id, booking_reference, description, idempotency_key, created_by)
      VALUES
        (v_payment.user_id, 'BOOKING_PAYMENT_REVERSAL', 'credit', v_amount, v_wallet.balance,
         NEW.booking_id, NEW.booking_reference,
         'JCoins returned because the unpaid booking expired',
         'booking-expiry-reversal-' || NEW.booking_id::text, v_payment.user_id)
      ON CONFLICT (idempotency_key) DO NOTHING;

      UPDATE public.booking_payments
         SET payment_status = 'failed', updated_at = now()
       WHERE payment_id = v_payment.payment_id;
    END IF;
  END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS trg_restore_jcoins_on_booking_expiry ON public.bookings;
CREATE TRIGGER trg_restore_jcoins_on_booking_expiry
AFTER UPDATE OF booking_status ON public.bookings
FOR EACH ROW EXECUTE FUNCTION public.restore_jcoins_on_unpaid_booking_expiry();

COMMENT ON FUNCTION public.confirm_booking_jcoins_payment(text,numeric,text) IS
  'Atomically confirms JCoins/cash/split payment selection, debits wallet once, and confirms full-JCoins bookings immediately.';

COMMIT;

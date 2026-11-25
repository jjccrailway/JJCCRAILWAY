-- JJCC Railways: preserve legacy pending receipts and let passengers cancel
-- only bookings that are still waiting for administrator receipt approval.
-- Run AFTER migration 20_pending_receipt_review_timer_fix.sql.
-- No cash refund is issued by this migration. JCoins debits are reversed safely.

BEGIN;

-- 1) Restore the pending-review state for receipts submitted before the timer fix.
--    This pauses those bookings even if an earlier expiry run marked the booking
--    or its passenger workflow rows as expired.
UPDATE public.booking_passenger_workflow AS bpw
   SET payment_status = 'pending_review',
       payment_deadline_at = NULL,
       updated_at = now()
 WHERE bpw.payment_status IN ('awaiting_payment', 'expired')
   AND EXISTS (
     SELECT 1
       FROM public.passenger_payment_submissions AS pps
      WHERE pps.workflow_id = bpw.workflow_id
        AND pps.status = 'pending_review'
   );

-- A legacy booking-wide receipt covers the remaining passenger workflow rows.
UPDATE public.booking_passenger_workflow AS bpw
   SET payment_status = 'pending_review',
       payment_deadline_at = NULL,
       updated_at = now()
 WHERE bpw.payment_status IN ('awaiting_payment', 'expired')
   AND EXISTS (
     SELECT 1
       FROM public.payment_submissions AS ps
      WHERE ps.booking_id = bpw.booking_id
        AND ps.status = 'pending_review'
   );

-- Restore pending bookings that an older expiry job may have marked expired.
-- The pending receipt is the source of truth: these bookings are not unpaid holds.
UPDATE public.bookings AS b
   SET booking_status = 'pending_payment',
       payment_deadline_at = NULL
 WHERE b.booking_status IN ('pending_payment', 'expired', 'pending_discount_verification')
   AND (
     EXISTS (
       SELECT 1 FROM public.payment_submissions AS ps
        WHERE ps.booking_id = b.booking_id AND ps.status = 'pending_review'
     )
     OR EXISTS (
       SELECT 1 FROM public.passenger_payment_submissions AS pps
        WHERE pps.booking_id = b.booking_id AND pps.status = 'pending_review'
     )
     OR EXISTS (
       SELECT 1 FROM public.booking_passenger_workflow AS bpw
        WHERE bpw.booking_id = b.booking_id AND bpw.payment_status = 'pending_review'
     )
   );

-- Repair passenger counts/fare snapshots where the old passenger expiry routine
-- zeroed them even though a workflow passenger is now protected by a pending receipt.
UPDATE public.bookings AS b
   SET total_passengers = counts.active_count,
       total_fare = CASE
         WHEN COALESCE(b.total_fare, 0) = 0 THEN counts.active_fare
         ELSE b.total_fare
       END,
       payment_deadline_at = NULL
  FROM (
    SELECT bpw.booking_id,
           COUNT(*) FILTER (WHERE bpw.payment_status IN
             ('pending_review', 'paid', 'awaiting_payment', 'awaiting_id'))::integer AS active_count,
           COALESCE(SUM(bpw.amount_due) FILTER (WHERE bpw.payment_status IN
             ('pending_review', 'paid', 'awaiting_payment', 'awaiting_id')), 0)::numeric(10,2) AS active_fare
      FROM public.booking_passenger_workflow AS bpw
     GROUP BY bpw.booking_id
  ) AS counts
 WHERE b.booking_id = counts.booking_id
   AND b.passenger_payment_workflow = true
   AND counts.active_count > 0
   AND (
     EXISTS (
       SELECT 1
         FROM public.payment_submissions AS ps
        WHERE ps.booking_id = b.booking_id AND ps.status = 'pending_review'
     )
     OR EXISTS (
       SELECT 1 FROM public.passenger_payment_submissions AS pps
        WHERE pps.booking_id = b.booking_id AND pps.status = 'pending_review'
     )
   );

-- 2) Keep the existing 24-hour-after-payment cancellation policy for confirmed
--    bookings, but exempt an unconfirmed booking whose receipt is still awaiting
--    review. The user, not the admin review timer, controls cancellation here.
CREATE OR REPLACE FUNCTION public.enforce_booking_cancellation_window()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $function$
DECLARE
  v_has_pending_receipt boolean := false;
BEGIN
  IF lower(COALESCE(NEW.booking_status, '')) = 'cancelled'
     AND lower(COALESCE(OLD.booking_status, '')) <> 'cancelled' THEN

    SELECT
      EXISTS (
        SELECT 1 FROM public.payment_submissions AS ps
         WHERE ps.booking_id = OLD.booking_id AND ps.status = 'pending_review'
      )
      OR EXISTS (
        SELECT 1 FROM public.passenger_payment_submissions AS pps
         WHERE pps.booking_id = OLD.booking_id AND pps.status = 'pending_review'
      )
      OR EXISTS (
        SELECT 1 FROM public.booking_passenger_workflow AS bpw
         WHERE bpw.booking_id = OLD.booking_id AND bpw.payment_status = 'pending_review'
      )
      INTO v_has_pending_receipt;

    IF lower(COALESCE(OLD.booking_status, '')) IN
         ('pending_payment', 'pending_discount_verification', 'expired')
       AND v_has_pending_receipt THEN
      NEW.cancelled_at := COALESCE(NEW.cancelled_at, now());
      RETURN NEW;
    END IF;

    IF NEW.paid_at IS NULL THEN
      RAISE EXCEPTION 'Only paid bookings can be cancelled under the standard cancellation policy.';
    END IF;

    IF now() > NEW.paid_at + interval '24 hours' THEN
      RAISE EXCEPTION 'The 24-hour cancellation window after payment has expired.';
    END IF;

    NEW.cancelled_at := COALESCE(NEW.cancelled_at, now());
  END IF;

  RETURN NEW;
END;
$function$;

-- 3) Passenger cancellation for a booking with a receipt pending admin review.
--    Passenger/seat link rows are deliberately retained for the booking history;
--    seat availability ignores cancelled bookings, so the seats become available.
CREATE OR REPLACE FUNCTION public.cancel_pending_approval_booking(
  p_booking_reference text,
  p_reason text DEFAULT 'Cancelled by passenger while awaiting administrator approval.'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $function$
DECLARE
  v_user_id uuid := auth.uid();
  v_booking public.bookings%ROWTYPE;
  v_sub record;
  v_wallet public.jcoins_wallets%ROWTYPE;
  v_coins numeric(10,2);
  v_jcoins_refunded numeric(10,2) := 0;
  v_idempotency_key text;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Please sign in before cancelling your booking.';
  END IF;

  IF p_booking_reference IS NULL OR btrim(p_booking_reference) = '' THEN
    RAISE EXCEPTION 'Booking reference is required.';
  END IF;

  SELECT * INTO v_booking
    FROM public.bookings
   WHERE booking_reference = upper(btrim(p_booking_reference))
     AND user_id = v_user_id
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Booking not found for this account.';
  END IF;

  IF lower(COALESCE(v_booking.booking_status, '')) NOT IN
       ('pending_payment', 'pending_discount_verification', 'expired') THEN
    RAISE EXCEPTION 'Only bookings awaiting payment approval can be cancelled here.';
  END IF;

  IF NOT (
    EXISTS (SELECT 1 FROM public.payment_submissions ps
             WHERE ps.booking_id = v_booking.booking_id AND ps.status = 'pending_review')
    OR EXISTS (SELECT 1 FROM public.passenger_payment_submissions pps
                WHERE pps.booking_id = v_booking.booking_id AND pps.status = 'pending_review')
    OR EXISTS (SELECT 1 FROM public.booking_passenger_workflow bpw
                WHERE bpw.booking_id = v_booking.booking_id AND bpw.payment_status = 'pending_review')
  ) THEN
    RAISE EXCEPTION 'This booking is no longer waiting for administrator approval. Refresh your bookings.';
  END IF;

  -- Change the booking state while the pending receipt still exists. The trigger
  -- above permits this unconfirmed, pending-review cancellation.
  UPDATE public.bookings
     SET booking_status = 'cancelled',
         payment_deadline_at = NULL,
         cancelled_at = COALESCE(cancelled_at, now())
   WHERE booking_id = v_booking.booking_id
     AND user_id = v_user_id;

  -- Return JCoins used by passenger-level payments, once per workflow row.
  IF NOT EXISTS (
    SELECT 1 FROM public.payment_submissions AS ps
     WHERE ps.booking_id = v_booking.booking_id AND ps.status = 'pending_review'
  ) THEN
    FOR v_sub IN
      SELECT bpw.workflow_id, bpw.user_id, bpw.jcoins_amount,
             bpw.payment_status, bpw.booking_id
        FROM public.booking_passenger_workflow AS bpw
       WHERE bpw.booking_id = v_booking.booking_id
         AND bpw.payment_status IN ('pending_review', 'paid')
         AND COALESCE(bpw.jcoins_amount, 0) > 0
       FOR UPDATE
    LOOP
    v_coins := round(COALESCE(v_sub.jcoins_amount, 0), 2);
    v_idempotency_key := 'pending-approval-cancel-workflow-' || v_sub.workflow_id::text;

    IF v_coins > 0 AND NOT EXISTS (
      SELECT 1 FROM public.jcoins_transactions jt
       WHERE jt.idempotency_key = v_idempotency_key
    ) THEN
      SELECT * INTO v_wallet
        FROM public.jcoins_wallets
       WHERE user_id = v_sub.user_id
       FOR UPDATE;

      IF NOT FOUND THEN
        RAISE EXCEPTION 'JCoins wallet not found. Cancellation was not completed.';
      END IF;

      UPDATE public.jcoins_wallets
         SET balance = balance + v_coins,
             total_spent = GREATEST(0, total_spent - v_coins),
             updated_at = now()
       WHERE user_id = v_sub.user_id
       RETURNING * INTO v_wallet;

      INSERT INTO public.jcoins_transactions(
        user_id, transaction_type, direction, amount, balance_after,
        booking_id, booking_reference, description, idempotency_key, created_by
      ) VALUES (
        v_sub.user_id, 'BOOKING_PAYMENT_REVERSAL', 'credit', v_coins,
        v_wallet.balance, v_booking.booking_id, v_booking.booking_reference,
        'JCoins returned because the passenger cancelled while payment approval was pending',
        v_idempotency_key, v_user_id
      );
      v_jcoins_refunded := v_jcoins_refunded + v_coins;
      END IF;
    END LOOP;
  END IF;

  -- Withdraw passenger-level receipts from the admin queue.
  UPDATE public.passenger_payment_submissions
     SET status = 'rejected',
         admin_note = 'Cancelled by passenger before administrator review.',
         reviewed_at = now(),
         reviewed_by = NULL
   WHERE booking_id = v_booking.booking_id
     AND status = 'pending_review';

  -- Expired is the existing terminal workflow value; the parent booking is
  -- cancelled, while passenger identity and seat-link history remain intact.
  UPDATE public.booking_passenger_workflow
     SET payment_status = 'expired',
         payment_deadline_at = NULL,
         jcoins_amount = 0,
         cash_due = amount_due,
         updated_at = now()
   WHERE booking_id = v_booking.booking_id
     AND payment_status IN ('pending_review', 'paid', 'awaiting_payment', 'awaiting_id');

  -- Rejecting a legacy booking-wide receipt invokes the existing database trigger
  -- that returns its JCoins portion exactly once, when applicable.
  UPDATE public.payment_submissions
     SET status = 'rejected',
         admin_note = 'Cancelled by passenger before administrator review.',
         reviewed_at = now(),
         reviewed_by = NULL
   WHERE booking_id = v_booking.booking_id
     AND status = 'pending_review';

  UPDATE public.booking_payments
     SET payment_status = 'failed',
         updated_at = now()
   WHERE booking_id = v_booking.booking_id
     AND payment_status IN ('created', 'approved');

  INSERT INTO public.user_notifications(
    user_id, booking_id, title, message, notification_type
  ) VALUES (
    v_user_id,
    v_booking.booking_id,
    'Booking cancelled',
    'Your booking ' || v_booking.booking_reference ||
      ' was cancelled while awaiting administrator payment approval. Its seats are now available. Any JCoins used were returned to your wallet. Cash already transferred may require separate refund handling.',
    'info'
  );

  RETURN jsonb_build_object(
    'success', true,
    'booking_reference', v_booking.booking_reference,
    'booking_status', 'cancelled',
    'jcoins_refunded', v_jcoins_refunded,
    'message', 'Booking cancelled successfully. Its seats are available again.'
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.cancel_pending_approval_booking(text, text)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.cancel_pending_approval_booking(text, text)
  TO authenticated;

COMMENT ON FUNCTION public.cancel_pending_approval_booking(text, text) IS
  'Allows the booking owner to cancel a booking with a receipt awaiting admin review; stops review, releases seats by status, and reverses JCoins without issuing a cash refund.';

COMMIT;

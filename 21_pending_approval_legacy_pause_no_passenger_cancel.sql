-- JJCC Railways: restore legacy receipt-pending bookings and keep approval-only flow.
-- Run AFTER 20_pending_receipt_review_timer_fix.sql.
-- This revision intentionally does NOT add passenger cancellation for pending approvals.
-- Pending receipts stay reserved until an administrator approves or rejects them.

BEGIN;

-- 1) Restore passenger-level workflows whose submitted receipts are still awaiting review.
--    Older expiry jobs may have changed these rows to expired/awaiting_payment.
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

-- A legacy booking-wide receipt protects all passenger rows in that booking.
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

-- Restore parent bookings from expired/pending-discount states when a receipt
-- is still pending. Clear the deadline so admin review is not timer-bound.
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

-- Restore passenger counts and fare totals from active workflow rows. This repairs
-- cards that showed 0 passengers after an older expiry routine altered the parent.
UPDATE public.bookings AS b
   SET total_passengers = counts.active_count,
       total_fare = counts.active_fare,
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

-- 2) Remove the temporary passenger-cancellation RPC if the earlier revision was run.
--    Users must not be able to cancel while a receipt is pending admin review.
DROP FUNCTION IF EXISTS public.cancel_pending_approval_booking(text, text);

-- 3) Restore the standard cancellation guard: passenger cancellations require
--    an approved/paid booking and remain subject to the existing 24-hour rule.
--    The internal railway cancellation flag is retained for staff/system operations.
CREATE OR REPLACE FUNCTION public.enforce_booking_cancellation_window()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $function$
BEGIN
  IF lower(COALESCE(NEW.booking_status, '')) = 'cancelled'
     AND lower(COALESCE(OLD.booking_status, '')) <> 'cancelled' THEN
    IF COALESCE(current_setting('app.railway_cancellation', true), 'false') = 'true' THEN
      NEW.cancelled_at := COALESCE(NEW.cancelled_at, now());
      RETURN NEW;
    END IF;

    IF NEW.paid_at IS NULL THEN
      RAISE EXCEPTION 'Only paid bookings can be cancelled.';
    END IF;

    IF now() > NEW.paid_at + interval '24 hours' THEN
      RAISE EXCEPTION 'The 24-hour cancellation window after payment confirmation has expired.';
    END IF;

    NEW.cancelled_at := COALESCE(NEW.cancelled_at, now());
  END IF;

  RETURN NEW;
END;
$function$;

-- 4) Allow admins to approve legacy pending receipts after the old 10-minute
--    deadline was cleared. If a deadline is still present, submission time must
--    still be within that original deadline. Rejections get a fresh 10-minute window.
CREATE OR REPLACE FUNCTION public.review_payment_submission(
  p_submission_id bigint,
  p_decision text,
  p_admin_note text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $function$
DECLARE
  v_role text;
  v_submission public.payment_submissions%ROWTYPE;
  v_booking public.bookings%ROWTYPE;
  v_title text;
  v_message text;
  v_new_deadline timestamptz;
BEGIN
  v_role := public.current_user_role();
  IF COALESCE(v_role, '') NOT IN ('admin', 'super_admin') THEN
    RAISE EXCEPTION 'Only an administrator can review receipts.';
  END IF;
  IF COALESCE(p_decision, '') NOT IN ('approved', 'rejected') THEN
    RAISE EXCEPTION 'Decision must be approved or rejected.';
  END IF;

  SELECT *
    INTO v_submission
    FROM public.payment_submissions
   WHERE submission_id = p_submission_id
   FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Receipt submission not found.';
  END IF;
  IF v_submission.status <> 'pending_review' THEN
    RAISE EXCEPTION 'This receipt has already been reviewed.';
  END IF;

  SELECT *
    INTO v_booking
    FROM public.bookings
   WHERE booking_id = v_submission.booking_id
   FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Booking not found.';
  END IF;

  IF p_decision = 'approved' THEN
    -- Compare submission time with the original deadline, not NOW().
    -- An on-time receipt remains approvable even if the admin reviews it later.
    IF v_booking.booking_status <> 'pending_payment'
       OR (v_booking.payment_deadline_at IS NOT NULL
           AND v_submission.submitted_at > v_booking.payment_deadline_at) THEN
      RAISE EXCEPTION 'This receipt was not submitted within the 10-minute payment window and cannot be approved.';
    END IF;

    UPDATE public.bookings
       SET booking_status = 'confirmed',
           paid_at = COALESCE(paid_at, now()),
           payment_deadline_at = NULL
     WHERE booking_id = v_booking.booking_id;

    UPDATE public.booking_passenger_workflow
       SET payment_status = 'paid',
           payment_deadline_at = NULL,
           updated_at = now()
     WHERE booking_id = v_booking.booking_id
       AND payment_status IN ('awaiting_payment', 'pending_review');

    UPDATE public.booking_payments
       SET payment_status = 'completed',
           amount = v_booking.total_fare,
           currency = COALESCE(currency, 'PHP'),
           completed_at = COALESCE(completed_at, now()),
           updated_at = now()
     WHERE payment_id = (
       SELECT bp.payment_id
         FROM public.booking_payments AS bp
        WHERE bp.booking_id = v_booking.booking_id
        ORDER BY bp.created_at DESC, bp.payment_id DESC
        LIMIT 1
     );

    IF NOT FOUND THEN
      INSERT INTO public.booking_payments(
        booking_id, user_id, provider, amount, currency,
        payment_status, completed_at, updated_at
      )
      VALUES (
        v_booking.booking_id, v_submission.user_id, 'manual_receipt',
        v_booking.total_fare, 'PHP', 'completed', now(), now()
      );
    END IF;

    v_title := 'Payment approved';
    v_message := 'Your receipt was approved. Your booking ' ||
                 v_booking.booking_reference || ' is now confirmed.';
  ELSE
    -- Rejection returns the booking to the passenger for a fresh 10-minute
    -- correction/upload window. Pending admin review itself never consumes time.
    v_new_deadline := now() + interval '10 minutes';

    UPDATE public.booking_passenger_workflow
       SET payment_status = 'awaiting_payment',
           payment_deadline_at = v_new_deadline,
           updated_at = now()
     WHERE booking_id = v_booking.booking_id
       AND payment_status IN ('awaiting_payment', 'pending_review');

    UPDATE public.bookings
       SET booking_status = 'pending_payment',
           payment_deadline_at = v_new_deadline
     WHERE booking_id = v_booking.booking_id;

    v_title := 'Payment receipt not approved';
    v_message := 'Your receipt for booking ' || v_booking.booking_reference ||
      ' was not approved. ' ||
      COALESCE(NULLIF(btrim(p_admin_note), ''),
               'Please upload a corrected receipt within the new 10-minute payment window.') ||
      ' Your reservation remains available during this correction period.';
  END IF;

  UPDATE public.payment_submissions
     SET status = p_decision,
         admin_note = NULLIF(btrim(p_admin_note), ''),
         reviewed_at = now(),
         reviewed_by = auth.uid()
   WHERE submission_id = p_submission_id;

  INSERT INTO public.user_notifications(
    user_id, booking_id, title, message, notification_type
  )
  VALUES (
    v_submission.user_id,
    v_submission.booking_id,
    v_title,
    v_message,
    CASE WHEN p_decision = 'approved' THEN 'success' ELSE 'warning' END
  );

  RETURN jsonb_build_object(
    'success', true,
    'decision', p_decision,
    'booking_reference', v_booking.booking_reference
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.review_payment_submission(bigint, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.review_payment_submission(bigint, text, text) TO authenticated;

COMMENT ON FUNCTION public.review_payment_submission(bigint, text, text) IS
  'Admin review accepts a receipt submitted within its original deadline; a NULL deadline denotes a legacy reservation paused for admin review.';

COMMIT;

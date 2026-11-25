-- JJCC Railways: a submitted receipt is no longer subject to the passenger's
-- 10-minute upload timer. Keep its passenger seats/details until admin review.
-- Run AFTER 19_preserve_pending_receipt_reservations.sql and migration 16.

-- 1) Passenger-level expiry: do not release any passenger belonging to a booking
-- that has a booking-wide receipt awaiting administrator review. The existing
-- passenger-level workflow already protects rows with payment_status=pending_review;
-- this extra guard covers the legacy booking-wide payment page's payment_submissions.
CREATE OR REPLACE FUNCTION public.expire_passenger_payment_holds()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_flow record;
  v_count integer := 0;
  v_remaining integer;
  v_total numeric(10,2);
BEGIN
  FOR v_flow IN
    SELECT bpw.*
      FROM public.booking_passenger_workflow AS bpw
     WHERE bpw.payment_status = 'awaiting_payment'
       AND bpw.payment_deadline_at IS NOT NULL
       AND bpw.payment_deadline_at <= now()
       AND NOT EXISTS (
         SELECT 1
           FROM public.payment_submissions AS ps
          WHERE ps.booking_id = bpw.booking_id
            AND ps.status = 'pending_review'
       )
     FOR UPDATE OF bpw SKIP LOCKED
  LOOP
    IF COALESCE(v_flow.jcoins_amount, 0) > 0 THEN
      UPDATE public.jcoins_wallets
         SET balance = balance + v_flow.jcoins_amount,
             total_spent = GREATEST(0, total_spent - v_flow.jcoins_amount),
             updated_at = now()
       WHERE user_id = v_flow.user_id;

      INSERT INTO public.jcoins_transactions(
        user_id, transaction_type, direction, amount, balance_after,
        booking_id, booking_reference, description, idempotency_key, created_by
      )
      SELECT v_flow.user_id, 'BOOKING_PAYMENT_REVERSAL', 'credit',
             v_flow.jcoins_amount, w.balance, v_flow.booking_id,
             b.booking_reference,
             'JCoins returned because the passenger payment window expired',
             'passenger-expiry-reversal-' || v_flow.workflow_id::text,
             v_flow.user_id
        FROM public.jcoins_wallets AS w
        JOIN public.bookings AS b ON b.booking_id = v_flow.booking_id
       WHERE w.user_id = v_flow.user_id
      ON CONFLICT (idempotency_key) DO NOTHING;
    END IF;

    DELETE FROM public.booking_passengers
     WHERE booking_id = v_flow.booking_id
       AND passenger_id = v_flow.passenger_id;
    DELETE FROM public.booking_return_passengers
     WHERE booking_id = v_flow.booking_id
       AND passenger_id = v_flow.passenger_id;

    UPDATE public.booking_passenger_workflow
       SET payment_status = 'expired',
           payment_deadline_at = NULL,
           updated_at = now()
     WHERE workflow_id = v_flow.workflow_id;

    SELECT COUNT(*)
      INTO v_remaining
      FROM public.booking_passenger_workflow
     WHERE booking_id = v_flow.booking_id
       AND payment_status <> 'expired';

    SELECT COALESCE(SUM(amount_due), 0)
      INTO v_total
      FROM public.booking_passenger_workflow
     WHERE booking_id = v_flow.booking_id
       AND payment_status <> 'expired';

    UPDATE public.bookings
       SET total_passengers = v_remaining,
           total_fare = v_total,
           booking_status = CASE
             WHEN v_remaining = 0 THEN 'expired'
             WHEN NOT EXISTS (
               SELECT 1 FROM public.booking_passenger_workflow AS x
                WHERE x.booking_id = v_flow.booking_id
                  AND x.payment_status NOT IN ('paid', 'expired')
             ) THEN 'confirmed'
             WHEN EXISTS (
               SELECT 1 FROM public.booking_passenger_workflow AS x
                WHERE x.booking_id = v_flow.booking_id
                  AND x.payment_status = 'awaiting_id'
             ) THEN 'pending_discount_verification'
             ELSE 'pending_payment'
           END,
           payment_deadline_at = (
             SELECT MIN(payment_deadline_at)
               FROM public.booking_passenger_workflow
              WHERE booking_id = v_flow.booking_id
                AND payment_status = 'awaiting_payment'
           ),
           paid_at = CASE
             WHEN v_remaining > 0 AND NOT EXISTS (
               SELECT 1 FROM public.booking_passenger_workflow AS x
                WHERE x.booking_id = v_flow.booking_id
                  AND x.payment_status NOT IN ('paid', 'expired')
             ) THEN COALESCE(paid_at, now())
             ELSE paid_at
           END
     WHERE booking_id = v_flow.booking_id;

    INSERT INTO public.user_notifications(
      user_id, booking_id, title, message, notification_type
    )
    VALUES (
      v_flow.user_id,
      v_flow.booking_id,
      'Passenger reservation expired',
      'The 10-minute payment period expired for one unpaid passenger. Only that passenger seat was released; other passengers remain reserved.',
      'warning'
    );

    v_count := v_count + 1;
  END LOOP;

  RETURN v_count;
END;
$function$;

REVOKE ALL ON FUNCTION public.expire_passenger_payment_holds()
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.expire_passenger_payment_holds()
  TO service_role;


-- 2) Legacy booking-wide expiry: preserve the booking while a receipt is pending.
CREATE OR REPLACE FUNCTION public.expire_pending_bookings()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_count integer;
BEGIN
  UPDATE public.bookings AS b
     SET booking_status = 'expired'
   WHERE b.booking_status = 'pending_payment'
     AND b.passenger_payment_workflow = false
     AND b.payment_deadline_at IS NOT NULL
     AND b.payment_deadline_at <= now()
     AND NOT EXISTS (
       SELECT 1
         FROM public.payment_submissions AS ps
        WHERE ps.booking_id = b.booking_id
          AND ps.status = 'pending_review'
     )
     AND NOT EXISTS (
       SELECT 1
         FROM public.passenger_payment_submissions AS pps
        WHERE pps.booking_id = b.booking_id
          AND pps.status = 'pending_review'
     )
     AND NOT EXISTS (
       SELECT 1
         FROM public.booking_passenger_workflow AS bpw
        WHERE bpw.booking_id = b.booking_id
          AND bpw.payment_status = 'pending_review'
     );

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$function$;

REVOKE ALL ON FUNCTION public.expire_pending_bookings()
  FROM PUBLIC, authenticated;
GRANT EXECUTE ON FUNCTION public.expire_pending_bookings()
  TO service_role;


-- 3) Keep the passenger workflow in sync when staff approve/reject a legacy
-- booking-wide receipt. Approval must not leave old passenger timers running.
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
       OR v_booking.payment_deadline_at IS NULL
       OR v_submission.submitted_at > v_booking.payment_deadline_at THEN
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

REVOKE ALL ON FUNCTION public.review_payment_submission(bigint, text, text)
  FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.review_payment_submission(bigint, text, text)
  TO authenticated;

COMMENT ON FUNCTION public.expire_passenger_payment_holds() IS
  'Expires only unpaid passenger holds. A submitted booking-wide receipt protects the reservation until staff review it.';
COMMENT ON FUNCTION public.review_payment_submission(bigint, text, text) IS
  'Admin review of a booking-wide receipt; pending review pauses expiry and approval completes linked passenger workflow rows.';

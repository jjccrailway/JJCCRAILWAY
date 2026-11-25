-- JJCC Railways: start the 10-minute payment hold when the passenger proceeds to Payment.
-- Run this once in Supabase SQL Editor before deploying the updated payment.html and script.js.
-- Existing bookings are not reset. A started payment window is never extended by page refreshes.

ALTER TABLE public.bookings
  ADD COLUMN IF NOT EXISTS payment_started_at timestamptz;

CREATE OR REPLACE FUNCTION public.start_booking_payment_window(
  p_booking_reference text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_booking public.bookings%ROWTYPE;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Please sign in before proceeding to payment.';
  END IF;

  SELECT *
    INTO v_booking
    FROM public.bookings
   WHERE upper(btrim(booking_reference)) = upper(btrim(p_booking_reference))
     AND user_id = auth.uid()
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Booking not found for this account.';
  END IF;

  IF lower(COALESCE(v_booking.booking_status, '')) <> 'pending_payment' THEN
    RAISE EXCEPTION 'This booking is not awaiting payment.';
  END IF;

  -- Set the start time once only. Refreshing the payment page will reuse this deadline.
  IF v_booking.payment_started_at IS NULL THEN
    IF EXISTS (
      SELECT 1
        FROM public.payment_submissions ps
       WHERE ps.booking_id = v_booking.booking_id
    ) THEN
      -- Legacy receipt already submitted: preserve its existing deadline.
      RETURN jsonb_build_object(
        'success', true,
        'payment_deadline_at', v_booking.payment_deadline_at
      );
    END IF;

    UPDATE public.bookings
       SET payment_started_at = now(),
           payment_deadline_at = now() + interval '10 minutes'
     WHERE booking_id = v_booking.booking_id
     RETURNING * INTO v_booking;
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'payment_deadline_at', v_booking.payment_deadline_at
  );
END;
$$;

REVOKE ALL ON FUNCTION public.start_booking_payment_window(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.start_booking_payment_window(text) TO authenticated;

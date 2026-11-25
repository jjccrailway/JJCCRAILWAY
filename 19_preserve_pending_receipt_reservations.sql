-- JJCC Railways: keep submitted receipts reserved until an administrator reviews them.
-- Run after 16_passenger_level_payment_workflow.sql.
-- This updates the existing scheduled expiry function; it does not change the
-- 10-minute deadline for passengers who have NOT submitted a receipt.

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
     -- Legacy receipt submissions remain protected while awaiting review.
     AND NOT EXISTS (
       SELECT 1
         FROM public.payment_submissions ps
        WHERE ps.booking_id = b.booking_id
          AND ps.status = 'pending_review'
     )
     -- Passenger-level receipts remain protected until Admin/Super Admin decides.
     AND NOT EXISTS (
       SELECT 1
         FROM public.passenger_payment_submissions pps
        WHERE pps.booking_id = b.booking_id
          AND pps.status = 'pending_review'
     )
     AND NOT EXISTS (
       SELECT 1
         FROM public.booking_passenger_workflow bpw
        WHERE bpw.booking_id = b.booking_id
          AND bpw.payment_status = 'pending_review'
     );

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$function$;

REVOKE ALL ON FUNCTION public.expire_pending_bookings() FROM PUBLIC, authenticated;
GRANT EXECUTE ON FUNCTION public.expire_pending_bookings() TO service_role;

COMMENT ON FUNCTION public.expire_pending_bookings() IS
  'Expires unpaid legacy bookings only when no legacy or passenger-level receipt is awaiting administrator review.';

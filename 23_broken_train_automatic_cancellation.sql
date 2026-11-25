-- JJCC Railways: cancel confirmed bookings and issue full JCoins refunds
-- when an Admin or Super Admin marks a train as BROKEN.
-- Run AFTER 10_jcoins_automatic_refunds_and_delay_compensation.sql.
-- This changes only the train-status RPC; existing booking and refund policies
-- remain unchanged. The existing railway cancellation RPC sends user notices
-- and credits 100% of the original fare to JCoins.

CREATE OR REPLACE FUNCTION public.set_train_status(p_train_id bigint, p_status text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_role text;
  v_reference text;
  v_cancelled integer := 0;
BEGIN
  v_role := public.current_user_role();

  IF COALESCE(v_role, '') NOT IN ('admin', 'super_admin') THEN
    RAISE EXCEPTION 'Only an administrator can update train status.';
  END IF;

  IF COALESCE(p_status, '') NOT IN ('active', 'broken', 'under_maintenance', 'out_of_service') THEN
    RAISE EXCEPTION 'Invalid train status.';
  END IF;

  UPDATE public.trains
     SET train_status = p_status,
         is_active = (p_status = 'active')
   WHERE train_id = p_train_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Train not found.';
  END IF;

  IF p_status = 'broken' THEN
    FOR v_reference IN
      SELECT b.booking_reference
        FROM public.bookings b
       WHERE b.train_id = p_train_id
         AND lower(COALESCE(b.booking_status, '')) = 'confirmed'
       FOR UPDATE
    LOOP
      PERFORM public.cancel_booking_by_railway(
        v_reference,
        'Train marked as broken by railway staff. Booking cancelled by JJCC Railways.'
      );
      v_cancelled := v_cancelled + 1;
    END LOOP;
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'train_id', p_train_id,
    'train_status', p_status,
    'is_active', (p_status = 'active'),
    'railway_cancelled_bookings', v_cancelled,
    'refund_method', CASE WHEN v_cancelled > 0 THEN 'JCoins' ELSE NULL END
  );
END;
$$;

REVOKE ALL ON FUNCTION public.set_train_status(bigint, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.set_train_status(bigint, text) TO authenticated;

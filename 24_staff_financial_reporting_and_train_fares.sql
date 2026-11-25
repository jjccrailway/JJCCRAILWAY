-- JJCC Railways: staff fare management + financial reporting repair
-- Run in Supabase SQL Editor AFTER the existing JJCC migrations.
-- Uses the existing public.train_stops table (not station_stops).
BEGIN;

CREATE OR REPLACE FUNCTION public.get_staff_train_fares()
RETURNS TABLE (
  train_id bigint,
  train_code text,
  train_name text,
  station_id bigint,
  station_name text,
  previous_station_name text,
  stop_order integer,
  fare_from_previous numeric
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE v_role text := public.current_user_role();
BEGIN
  IF COALESCE(v_role,'') NOT IN ('admin','super_admin') THEN
    RAISE EXCEPTION 'Only Admin or Super Admin can view train fares.';
  END IF;

  RETURN QUERY
  SELECT ts.train_id::bigint,
         tr.train_code::text,
         tr.train_name::text,
         ts.station_id::bigint,
         st.station_name::text,
         prev_st.station_name::text,
         ts.stop_order::integer,
         ts.fare_from_previous::numeric
    FROM public.train_stops ts
    JOIN public.trains tr ON tr.train_id = ts.train_id
    JOIN public.stations st ON st.station_id = ts.station_id
    LEFT JOIN public.train_stops prev_ts
      ON prev_ts.train_id = ts.train_id
     AND prev_ts.stop_order = ts.stop_order - 1
    LEFT JOIN public.stations prev_st ON prev_st.station_id = prev_ts.station_id
   WHERE COALESCE(tr.train_code,'') NOT LIKE 'RTG-%'
   ORDER BY tr.train_code, ts.stop_order;
END;
$$;

CREATE OR REPLACE FUNCTION public.update_staff_train_fare(
  p_train_id bigint,
  p_station_id bigint,
  p_fare numeric
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE v_role text := public.current_user_role(); v_rows integer;
BEGIN
  IF COALESCE(v_role,'') NOT IN ('admin','super_admin') THEN
    RAISE EXCEPTION 'Only Admin or Super Admin can update train fares.';
  END IF;
  IF p_fare IS NULL OR p_fare < 0 OR p_fare > 100000 THEN
    RAISE EXCEPTION 'Enter a valid fare between ₱0 and ₱100,000.';
  END IF;

  UPDATE public.train_stops
     SET fare_from_previous = round(p_fare,2)
   WHERE train_id = p_train_id AND station_id = p_station_id;
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  IF v_rows = 0 THEN RAISE EXCEPTION 'Train segment was not found.'; END IF;

  RETURN jsonb_build_object(
    'success', true,
    'train_id', p_train_id,
    'station_id', p_station_id,
    'fare_from_previous', round(p_fare,2),
    'applies_to', 'future reservations only'
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.get_staff_financial_summary(p_days integer DEFAULT 7)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_role text := public.current_user_role();
  v_days integer := GREATEST(1, LEAST(COALESCE(p_days,7),90));
  v_cash_booking numeric(14,2) := 0;
  v_cash_passenger numeric(14,2) := 0;
  v_jcoins numeric(14,2) := 0;
  v_legacy numeric(14,2) := 0;
  v_refunds numeric(14,2) := 0;
  v_gross numeric(14,2) := 0;
  v_daily jsonb;
  v_recent jsonb;
BEGIN
  IF COALESCE(v_role,'') NOT IN ('admin','super_admin') THEN
    RAISE EXCEPTION 'Only Admin or Super Admin can view financial reports.';
  END IF;

  -- Cash portion for ordinary booking-level payments.
  SELECT COALESCE(SUM(bp.amount),0)::numeric(14,2)
    INTO v_cash_booking
    FROM public.booking_payments bp
    JOIN public.bookings b ON b.booking_id = bp.booking_id
   WHERE bp.payment_status = 'completed'
     AND COALESCE(b.passenger_payment_workflow,false) = false;

  -- Passenger-level cash receipts are recorded per approved passenger submission.
  SELECT COALESCE(SUM(ps.cash_amount),0)::numeric(14,2)
    INTO v_cash_passenger
    FROM public.passenger_payment_submissions ps
    JOIN public.bookings b ON b.booking_id = ps.booking_id
   WHERE ps.status = 'approved'
     AND COALESCE(b.passenger_payment_workflow,false) = true;

  -- JCoins ticket payments are recorded as BOOKING_PAYMENT debits for both workflows.
  SELECT COALESCE(SUM(
           CASE
             WHEN lower(direction)='debit' AND upper(transaction_type)='BOOKING_PAYMENT' THEN amount
             WHEN lower(direction)='credit' AND upper(transaction_type)='BOOKING_PAYMENT_REVERSAL' THEN -amount
             ELSE 0
           END
         ),0)::numeric(14,2)
    INTO v_jcoins
    FROM public.jcoins_transactions
   WHERE upper(transaction_type) IN ('BOOKING_PAYMENT','BOOKING_PAYMENT_REVERSAL');

  -- Legacy confirmed bookings may predate payment ledger rows and paid_at migration.
  -- Only use total_fare when there is no cash-payment row and no JCoins debit for that booking.
  SELECT COALESCE(SUM(b.total_fare),0)::numeric(14,2)
    INTO v_legacy
    FROM public.bookings b
   WHERE lower(COALESCE(b.booking_status,'')) = 'confirmed'
     AND b.paid_at IS NOT NULL
     AND COALESCE(b.passenger_payment_workflow,false) = false
     AND NOT EXISTS (
       SELECT 1 FROM public.booking_payments bp
        WHERE bp.booking_id = b.booking_id AND bp.payment_status = 'completed'
     )
     AND NOT EXISTS (
       SELECT 1 FROM public.jcoins_transactions jt
        WHERE jt.booking_id = b.booking_id
          AND lower(jt.direction) = 'debit'
          AND upper(jt.transaction_type) = 'BOOKING_PAYMENT'
     );

  SELECT COALESCE(SUM(amount),0)::numeric(14,2)
    INTO v_refunds
    FROM public.jcoins_transactions
   WHERE lower(direction) = 'credit'
     AND upper(transaction_type) = 'REFUND_CREDIT';

  v_gross := v_cash_booking + v_cash_passenger + v_jcoins + v_legacy;

  -- Daily gross combines the actual cash receipt, passenger cash receipt,
  -- JCoins debit, and legacy fallback dates; refund credits are shown separately.
  WITH day_series AS (
    SELECT generate_series(
      (CURRENT_DATE - (v_days - 1))::date,
      CURRENT_DATE::date,
      interval '1 day'
    )::date AS day
  ),
  entries AS (
    SELECT (bp.completed_at AT TIME ZONE 'Asia/Manila')::date AS day,
           bp.amount::numeric AS amount, 'payment'::text AS kind
      FROM public.booking_payments bp
      JOIN public.bookings b ON b.booking_id = bp.booking_id
     WHERE bp.payment_status='completed'
       AND COALESCE(b.passenger_payment_workflow,false)=false
       AND bp.completed_at >= (CURRENT_DATE - (v_days - 1))::timestamptz
    UNION ALL
    SELECT (ps.reviewed_at AT TIME ZONE 'Asia/Manila')::date,
           ps.cash_amount::numeric, 'payment'
      FROM public.passenger_payment_submissions ps
      JOIN public.bookings b ON b.booking_id=ps.booking_id
     WHERE ps.status='approved'
       AND COALESCE(b.passenger_payment_workflow,false)=true
       AND ps.reviewed_at >= (CURRENT_DATE - (v_days - 1))::timestamptz
    UNION ALL
    SELECT (jt.created_at AT TIME ZONE 'Asia/Manila')::date,
           jt.amount::numeric, 'payment'
      FROM public.jcoins_transactions jt
     WHERE lower(jt.direction)='debit'
       AND upper(jt.transaction_type)='BOOKING_PAYMENT'
       AND jt.created_at >= (CURRENT_DATE - (v_days - 1))::timestamptz
    UNION ALL
    SELECT (jt.created_at AT TIME ZONE 'Asia/Manila')::date,
           -jt.amount::numeric, 'payment'
      FROM public.jcoins_transactions jt
     WHERE lower(jt.direction)='credit'
       AND upper(jt.transaction_type)='BOOKING_PAYMENT_REVERSAL'
       AND jt.created_at >= (CURRENT_DATE - (v_days - 1))::timestamptz
    UNION ALL
    SELECT (b.paid_at AT TIME ZONE 'Asia/Manila')::date,
           b.total_fare::numeric, 'payment'
      FROM public.bookings b
     WHERE lower(COALESCE(b.booking_status,''))='confirmed'
       AND b.paid_at IS NOT NULL
       AND COALESCE(b.passenger_payment_workflow,false)=false
       AND b.paid_at >= (CURRENT_DATE - (v_days - 1))::timestamptz
       AND NOT EXISTS (SELECT 1 FROM public.booking_payments bp WHERE bp.booking_id=b.booking_id AND bp.payment_status='completed')
       AND NOT EXISTS (SELECT 1 FROM public.jcoins_transactions jt WHERE jt.booking_id=b.booking_id AND lower(jt.direction)='debit' AND upper(jt.transaction_type)='BOOKING_PAYMENT')
    UNION ALL
    SELECT (jt.created_at AT TIME ZONE 'Asia/Manila')::date,
           jt.amount::numeric, 'refund'
      FROM public.jcoins_transactions jt
     WHERE lower(jt.direction)='credit'
       AND upper(jt.transaction_type)='REFUND_CREDIT'
       AND jt.created_at >= (CURRENT_DATE - (v_days - 1))::timestamptz
  ),
  daily_totals AS (
    SELECT ds.day,
           COALESCE(SUM(e.amount) FILTER (WHERE e.kind='payment'),0)::numeric(14,2) AS gross,
           COALESCE(SUM(e.amount) FILTER (WHERE e.kind='refund'),0)::numeric(14,2) AS refunds
      FROM day_series ds
      LEFT JOIN entries e ON e.day=ds.day
     GROUP BY ds.day
  )
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'date', d.day,
           'gross', d.gross,
           'refunds', d.refunds,
           'net', d.gross - d.refunds
         ) ORDER BY d.day), '[]'::jsonb)
    INTO v_daily
    FROM daily_totals d;

  SELECT COALESCE(jsonb_agg(to_jsonb(q) ORDER BY q.created_at DESC), '[]'::jsonb)
    INTO v_recent
    FROM (
      SELECT transaction_id, transaction_type, direction, amount,
             booking_reference, description, created_at
        FROM public.jcoins_transactions
       ORDER BY created_at DESC
       LIMIT 10
    ) q;

  RETURN jsonb_build_object(
    'gross', v_gross,
    'cash_booking', v_cash_booking,
    'cash_passenger', v_cash_passenger,
    'jcoins', v_jcoins,
    'legacy', v_legacy,
    'refunds', v_refunds,
    'net', v_gross - v_refunds,
    'daily', v_daily,
    'recent_transactions', v_recent
  );
END;
$$;

REVOKE ALL ON FUNCTION public.get_staff_train_fares() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.update_staff_train_fare(bigint,bigint,numeric) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.get_staff_financial_summary(integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_staff_train_fares() TO authenticated;
GRANT EXECUTE ON FUNCTION public.update_staff_train_fare(bigint,bigint,numeric) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_staff_financial_summary(integer) TO authenticated;

COMMIT;

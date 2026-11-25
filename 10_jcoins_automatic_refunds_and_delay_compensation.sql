-- JJCC Railways: automatic JCoins refunds and delay compensation
-- Run AFTER 09_jcoins_wallet_foundation.sql in Supabase SQL Editor.
-- Back up the database first. This migration uses the existing bookings,
-- booking_cancellation_requests, jcoins_wallets, and jcoins_transactions tables.
-- Delay incidents must be recorded from verified railway arrival data by staff;
-- compensation credits are then calculated and issued automatically for eligible bookings.

BEGIN;

-- Keep the cancellation cutoff anchored to payment confirmation (paid_at),
-- not departure time or booking creation time.
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

-- Passenger cancellation: immediate 50% JCoins refund, no admin review.
CREATE OR REPLACE FUNCTION public.cancel_booking(
  p_booking_reference text,
  p_reason text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_user_id uuid := auth.uid();
  v_booking public.bookings%ROWTYPE;
  v_reason text;
  v_refund numeric(12,2);
  v_balance numeric(12,2);
  v_tx_id bigint;
BEGIN
  IF v_user_id IS NULL THEN RAISE EXCEPTION 'Please sign in before cancelling your booking.'; END IF;
  IF COALESCE(pg_catalog.btrim(p_booking_reference), '') = '' THEN RAISE EXCEPTION 'Booking reference is required.'; END IF;
  v_reason := pg_catalog.btrim(p_reason);
  IF COALESCE(v_reason, '') = '' OR pg_catalog.length(v_reason) > 500 THEN
    RAISE EXCEPTION 'Please provide a valid cancellation reason.';
  END IF;

  SELECT b.* INTO v_booking
    FROM public.bookings b
   WHERE b.booking_reference = pg_catalog.upper(pg_catalog.btrim(p_booking_reference))
     AND b.user_id = v_user_id
   FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Booking not found or you do not have permission to cancel it.'; END IF;
  IF pg_catalog.lower(v_booking.booking_status) <> 'confirmed' THEN
    RAISE EXCEPTION 'Only confirmed bookings can be cancelled.';
  END IF;
  IF v_booking.paid_at IS NULL THEN RAISE EXCEPTION 'This booking has no recorded payment confirmation.'; END IF;
  IF now() > v_booking.paid_at + interval '24 hours' THEN
    RAISE EXCEPTION 'The 24-hour cancellation window after payment confirmation has expired.';
  END IF;

  v_refund := pg_catalog.round(COALESCE(v_booking.total_fare, 0) * 0.50, 2);
  IF v_refund <= 0 THEN RAISE EXCEPTION 'The calculated refund amount is invalid.'; END IF;

  UPDATE public.bookings
     SET booking_status = 'cancelled', cancelled_at = COALESCE(cancelled_at, now())
   WHERE booking_id = v_booking.booking_id AND user_id = v_user_id;

  INSERT INTO public.booking_cancellation_requests
    (booking_id, user_id, booking_reference, reason, original_fare, refund_amount, request_status)
  VALUES
    (v_booking.booking_id, v_user_id, v_booking.booking_reference, v_reason,
     v_booking.total_fare, v_refund, 'completed')
  ON CONFLICT (booking_id) DO UPDATE
    SET user_id = EXCLUDED.user_id,
        booking_reference = EXCLUDED.booking_reference,
        reason = EXCLUDED.reason,
        original_fare = EXCLUDED.original_fare,
        refund_amount = EXCLUDED.refund_amount,
        request_status = 'completed';

  INSERT INTO public.jcoins_wallets(user_id) VALUES (v_user_id)
  ON CONFLICT (user_id) DO NOTHING;
  SELECT balance INTO v_balance FROM public.jcoins_wallets WHERE user_id = v_user_id FOR UPDATE;
  v_balance := v_balance + v_refund;
  UPDATE public.jcoins_wallets
     SET balance = v_balance,
         total_earned = total_earned + v_refund,
         updated_at = now()
   WHERE user_id = v_user_id;

  INSERT INTO public.jcoins_transactions
    (user_id, transaction_type, direction, amount, balance_after, booking_id,
     booking_reference, description, idempotency_key, created_by)
  VALUES
    (v_user_id, 'REFUND_CREDIT', 'credit', v_refund, v_balance,
     v_booking.booking_id, v_booking.booking_reference,
     'Automatic 50% voluntary cancellation refund credited to JCoins.',
     'voluntary-refund:booking:' || v_booking.booking_id::text, v_user_id)
  RETURNING transaction_id INTO v_tx_id;

  INSERT INTO public.user_notifications(user_id, booking_id, title, message, notification_type)
  VALUES (v_user_id, v_booking.booking_id, 'Refund credited to JCoins',
          'Your booking was cancelled. ' || v_refund::text || ' JCoins have been credited to your wallet.',
          'success');

  RETURN pg_catalog.jsonb_build_object(
    'booking_reference', v_booking.booking_reference,
    'booking_status', 'cancelled',
    'original_fare', v_booking.total_fare,
    'refund_amount', v_refund,
    'refund_method', 'JCoins',
    'jcoins_balance', v_balance,
    'transaction_id', v_tx_id,
    'request_status', 'completed',
    'message', 'Booking cancelled and refund credited to JCoins immediately.'
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.cancel_booking(text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.cancel_booking(text, text) TO authenticated;

-- Railway-confirmed cancellations: 100% of original fare credited to JCoins.
CREATE OR REPLACE FUNCTION public.cancel_booking_by_railway(
  p_booking_reference text,
  p_reason text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $function$
DECLARE
  v_role text := public.current_user_role()::text;
  v_booking public.bookings%ROWTYPE;
  v_refund numeric(12,2);
  v_balance numeric(12,2);
BEGIN
  IF COALESCE(v_role,'') NOT IN ('admin','super_admin') THEN
    RAISE EXCEPTION 'Only authorized railway staff can record a railway-initiated cancellation.';
  END IF;
  SELECT * INTO v_booking FROM public.bookings
   WHERE booking_reference = upper(btrim(p_booking_reference))
   FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Booking not found.'; END IF;
  IF lower(v_booking.booking_status) <> 'confirmed' THEN RAISE EXCEPTION 'Only confirmed bookings can be cancelled.'; END IF;
  v_refund := round(COALESCE(v_booking.total_fare,0),2);
  IF v_refund <= 0 THEN RAISE EXCEPTION 'The original fare is invalid.'; END IF;

  PERFORM set_config('app.railway_cancellation','true',true);
  UPDATE public.bookings SET booking_status='cancelled', cancelled_at=COALESCE(cancelled_at,now())
   WHERE booking_id=v_booking.booking_id;
  PERFORM set_config('app.railway_cancellation','false',true);
  INSERT INTO public.booking_cancellation_requests
    (booking_id,user_id,booking_reference,reason,original_fare,refund_amount,request_status)
  VALUES (v_booking.booking_id,v_booking.user_id,v_booking.booking_reference,
          COALESCE(NULLIF(btrim(p_reason),''),'Railway-initiated cancellation'),
          v_booking.total_fare,v_refund,'completed')
  ON CONFLICT (booking_id) DO UPDATE SET
    reason=EXCLUDED.reason, original_fare=EXCLUDED.original_fare,
    refund_amount=EXCLUDED.refund_amount, request_status='completed';

  INSERT INTO public.jcoins_wallets(user_id) VALUES(v_booking.user_id)
  ON CONFLICT(user_id) DO NOTHING;
  SELECT balance INTO v_balance FROM public.jcoins_wallets WHERE user_id=v_booking.user_id FOR UPDATE;
  v_balance := v_balance + v_refund;
  UPDATE public.jcoins_wallets SET balance=v_balance,total_earned=total_earned+v_refund,updated_at=now()
   WHERE user_id=v_booking.user_id;
  INSERT INTO public.jcoins_transactions
    (user_id,transaction_type,direction,amount,balance_after,booking_id,booking_reference,description,idempotency_key,created_by)
  VALUES (v_booking.user_id,'REFUND_CREDIT','credit',v_refund,v_balance,v_booking.booking_id,
          v_booking.booking_reference,'Automatic 100% railway-initiated cancellation refund credited to JCoins.',
          'railway-refund:booking:'||v_booking.booking_id::text,auth.uid());
  INSERT INTO public.user_notifications(user_id,booking_id,title,message,notification_type)
  VALUES(v_booking.user_id,v_booking.booking_id,'Railway cancellation refund credited',
         v_refund::text||' JCoins have been credited to your wallet for the railway-initiated cancellation.','success');
  RETURN jsonb_build_object('booking_reference',v_booking.booking_reference,'booking_status','cancelled',
                            'refund_amount',v_refund,'refund_method','JCoins','jcoins_balance',v_balance);
END;
$function$;
REVOKE ALL ON FUNCTION public.cancel_booking_by_railway(text,text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.cancel_booking_by_railway(text,text) TO authenticated;

-- Verified train arrival incidents. One incident per train, travel date, and destination.
CREATE TABLE IF NOT EXISTS public.train_delay_incidents (
  incident_id bigint GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
  train_id bigint NOT NULL REFERENCES public.trains(train_id) ON DELETE RESTRICT,
  travel_date date NOT NULL,
  arrival_station_id bigint NOT NULL REFERENCES public.stations(station_id) ON DELETE RESTRICT,
  actual_arrival_at timestamptz NOT NULL,
  delay_minutes integer NOT NULL CHECK (delay_minutes >= 0),
  compensation_percent numeric(5,2) NOT NULL CHECK (compensation_percent IN (0,25,50,100)),
  recorded_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  recorded_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(train_id, travel_date, arrival_station_id)
);
ALTER TABLE public.train_delay_incidents ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Users read delay incidents for their bookings" ON public.train_delay_incidents;
CREATE POLICY "Users read delay incidents for their bookings" ON public.train_delay_incidents
  FOR SELECT TO authenticated USING (
    EXISTS (SELECT 1 FROM public.bookings b
      WHERE b.train_id=train_delay_incidents.train_id
        AND b.travel_date=train_delay_incidents.travel_date
        AND b.arrival_station_id=train_delay_incidents.arrival_station_id
        AND b.user_id=auth.uid())
    OR COALESCE(public.current_user_role()::text,'') IN ('admin','super_admin')
  );
GRANT SELECT ON public.train_delay_incidents TO authenticated;
REVOKE ALL ON public.train_delay_incidents FROM anon;

-- Called only by authorized staff when actual arrival data is verified.
-- For each eligible confirmed booking, compensation is computed against scheduled
-- arrival (travel_date + arrival_time, Asia/Manila) and credited immediately.
CREATE OR REPLACE FUNCTION public.record_train_delay_incident(
  p_train_id bigint,
  p_travel_date date,
  p_arrival_station_id bigint,
  p_actual_arrival_at timestamptz
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $function$
DECLARE
  v_role text := public.current_user_role()::text;
  v_delay integer;
  v_percent numeric(5,2);
  v_incident_id bigint;
  v_booking record;
  v_scheduled timestamptz;
  v_amount numeric(12,2);
  v_balance numeric(12,2);
  v_count integer := 0;
BEGIN
  IF COALESCE(v_role,'') NOT IN ('admin','super_admin') THEN
    RAISE EXCEPTION 'Only authorized railway staff can record verified train arrival data.';
  END IF;
  IF p_actual_arrival_at IS NULL THEN RAISE EXCEPTION 'Actual arrival timestamp is required.'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.bookings b
    WHERE b.train_id=p_train_id AND b.travel_date=p_travel_date
      AND b.arrival_station_id=p_arrival_station_id AND b.booking_status='confirmed') THEN
    RAISE EXCEPTION 'No confirmed bookings were found for this train, date, and destination.';
  END IF;
  SELECT min(((b.travel_date + b.arrival_time::time) AT TIME ZONE 'Asia/Manila'))
    INTO v_scheduled
    FROM public.bookings b
   WHERE b.train_id=p_train_id AND b.travel_date=p_travel_date
     AND b.arrival_station_id=p_arrival_station_id AND b.booking_status='confirmed';
  IF v_scheduled IS NULL THEN
    RAISE EXCEPTION 'Scheduled arrival time is missing for the selected destination.';
  END IF;
  v_delay := greatest(0, floor(extract(epoch FROM (p_actual_arrival_at - v_scheduled))/60)::integer);
  v_percent := CASE WHEN v_delay < 30 THEN 0 WHEN v_delay < 60 THEN 25 WHEN v_delay < 120 THEN 50 ELSE 100 END;

  INSERT INTO public.train_delay_incidents
    (train_id,travel_date,arrival_station_id,actual_arrival_at,delay_minutes,compensation_percent,recorded_by)
  VALUES (p_train_id,p_travel_date,p_arrival_station_id,p_actual_arrival_at,v_delay,v_percent,auth.uid())
  ON CONFLICT (train_id,travel_date,arrival_station_id) DO NOTHING
  RETURNING incident_id INTO v_incident_id;
  IF v_incident_id IS NULL THEN RAISE EXCEPTION 'A delay incident has already been recorded for this train, date, and destination.'; END IF;

  IF v_percent > 0 THEN
    FOR v_booking IN
      SELECT b.booking_id,b.user_id,b.booking_reference,b.total_fare
        FROM public.bookings b
       WHERE b.train_id=p_train_id AND b.travel_date=p_travel_date
         AND b.arrival_station_id=p_arrival_station_id
         AND lower(b.booking_status)='confirmed'
    LOOP
      v_amount := round(COALESCE(v_booking.total_fare,0) * v_percent / 100.0,2);
      IF v_amount > 0 THEN
        INSERT INTO public.jcoins_wallets(user_id) VALUES(v_booking.user_id)
        ON CONFLICT(user_id) DO NOTHING;
        SELECT balance INTO v_balance FROM public.jcoins_wallets WHERE user_id=v_booking.user_id FOR UPDATE;
        v_balance := v_balance + v_amount;
        UPDATE public.jcoins_wallets SET balance=v_balance,total_earned=total_earned+v_amount,updated_at=now()
         WHERE user_id=v_booking.user_id;
        INSERT INTO public.jcoins_transactions
          (user_id,transaction_type,direction,amount,balance_after,booking_id,booking_reference,description,idempotency_key,created_by)
        VALUES (v_booking.user_id,'DELAY_COMPENSATION','credit',v_amount,v_balance,
                v_booking.booking_id,v_booking.booking_reference,
                'Automatic delay compensation ('||v_percent::text||'%) based on verified actual arrival.',
                'delay-compensation:incident:'||v_incident_id::text||':booking:'||v_booking.booking_id::text,
                auth.uid());
        INSERT INTO public.user_notifications(user_id,booking_id,title,message,notification_type)
        VALUES(v_booking.user_id,v_booking.booking_id,'Delay compensation credited',
               v_amount::text||' JCoins have been credited to your wallet for a '||v_delay::text||'-minute arrival delay.','success');
        v_count := v_count + 1;
      END IF;
    END LOOP;
  END IF;

  RETURN jsonb_build_object('incident_id',v_incident_id,'delay_minutes',v_delay,
    'compensation_percent',v_percent,'credited_bookings',v_count,
    'actual_arrival_at',p_actual_arrival_at,
    'message',CASE WHEN v_percent=0 THEN 'Delay recorded. No compensation is due below 30 minutes.'
                   ELSE 'Delay recorded and eligible JCoins compensation credited automatically.' END);
END;
$function$;
REVOKE ALL ON FUNCTION public.record_train_delay_incident(bigint,date,bigint,timestamptz) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.record_train_delay_incident(bigint,date,bigint,timestamptz) TO authenticated;

COMMENT ON FUNCTION public.cancel_booking(text,text) IS
  'Immediately cancels a paid booking within 24 hours after paid_at and credits 50% of original fare to JCoins; no admin approval.';
COMMENT ON FUNCTION public.record_train_delay_incident(bigint,date,bigint,timestamptz) IS
  'Staff records verified actual arrival; database calculates delay compensation tiers and credits eligible confirmed bookings to JCoins automatically.';

COMMIT;

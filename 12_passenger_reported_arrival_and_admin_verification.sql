-- JJCC Railways: passenger reports actual arrival; Admin verifies before approval/credit.
-- Run AFTER migrations 09, 10 and 11. Does not auto-credit compensation.
BEGIN;

ALTER TABLE public.delay_compensation_requests
  ALTER COLUMN incident_id DROP NOT NULL;
ALTER TABLE public.delay_compensation_requests
  ADD COLUMN IF NOT EXISTS scheduled_arrival_at timestamptz,
  ADD COLUMN IF NOT EXISTS reported_arrival_at timestamptz,
  ADD COLUMN IF NOT EXISTS reported_delay_minutes integer,
  ADD COLUMN IF NOT EXISTS verified_actual_arrival_at timestamptz,
  ADD COLUMN IF NOT EXISTS verified_delay_minutes integer;

ALTER TABLE public.delay_compensation_requests
  DROP CONSTRAINT IF EXISTS delay_compensation_requests_compensation_percent_check;
ALTER TABLE public.delay_compensation_requests
  DROP CONSTRAINT IF EXISTS delay_compensation_requests_compensation_amount_check;
ALTER TABLE public.delay_compensation_requests
  ADD CONSTRAINT delay_comp_requests_percent_valid CHECK (compensation_percent IN (0,25,50,100)),
  ADD CONSTRAINT delay_comp_requests_amount_valid CHECK (compensation_amount >= 0);

ALTER TABLE public.delay_compensation_requests
  DROP CONSTRAINT IF EXISTS delay_compensation_requests_booking_id_incident_id_key;

-- Preserve any requests created by migration 11 by copying their previously
-- recorded verified arrival into the new report/verification columns.
UPDATE public.delay_compensation_requests r
   SET scheduled_arrival_at = COALESCE(r.scheduled_arrival_at,
         ((b.travel_date + b.arrival_time::time) AT TIME ZONE 'Asia/Manila') +
         CASE WHEN b.arrival_time::time <= b.departure_time::time THEN interval '1 day' ELSE interval '0 day' END),
       reported_arrival_at = COALESCE(r.reported_arrival_at,
         (SELECT i.actual_arrival_at FROM public.train_delay_incidents i WHERE i.incident_id=r.incident_id)),
       reported_delay_minutes = COALESCE(r.reported_delay_minutes,
         (SELECT i.delay_minutes FROM public.train_delay_incidents i WHERE i.incident_id=r.incident_id)),
       verified_actual_arrival_at = COALESCE(r.verified_actual_arrival_at,
         (SELECT i.actual_arrival_at FROM public.train_delay_incidents i WHERE i.incident_id=r.incident_id)),
       verified_delay_minutes = COALESCE(r.verified_delay_minutes,
         (SELECT i.delay_minutes FROM public.train_delay_incidents i WHERE i.incident_id=r.incident_id))
  FROM public.bookings b
 WHERE r.booking_id = b.booking_id;

DROP FUNCTION IF EXISTS public.request_delay_compensation(text);
CREATE OR REPLACE FUNCTION public.request_delay_compensation(
  p_booking_reference text,
  p_reported_arrival_at timestamptz
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $function$
DECLARE
  v_user uuid := auth.uid();
  v_booking public.bookings%ROWTYPE;
  v_scheduled timestamptz;
  v_reported_delay integer;
  v_percent numeric(5,2);
  v_amount numeric(12,2);
  v_request_id bigint;
BEGIN
  IF v_user IS NULL THEN RAISE EXCEPTION 'Please sign in to request delay compensation.'; END IF;
  IF p_reported_arrival_at IS NULL THEN RAISE EXCEPTION 'Please enter the actual arrival date and time.'; END IF;

  SELECT * INTO v_booking FROM public.bookings
   WHERE booking_reference=upper(btrim(p_booking_reference)) AND user_id=v_user
   FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Booking not found for your account.'; END IF;
  IF lower(v_booking.booking_status) <> 'confirmed' THEN
    RAISE EXCEPTION 'Only confirmed bookings can request delay compensation.';
  END IF;
  IF EXISTS (SELECT 1 FROM public.delay_compensation_requests WHERE booking_id=v_booking.booking_id) THEN
    RAISE EXCEPTION 'A delay compensation request has already been submitted for this booking.';
  END IF;

  v_scheduled := (v_booking.travel_date + v_booking.arrival_time::time) AT TIME ZONE 'Asia/Manila';
  IF v_booking.arrival_time::time <= v_booking.departure_time::time THEN
    v_scheduled := v_scheduled + interval '1 day';
  END IF;
  IF p_reported_arrival_at < v_scheduled - interval '24 hours'
     OR p_reported_arrival_at > v_scheduled + interval '7 days' THEN
    RAISE EXCEPTION 'The reported arrival date and time is outside the valid range for this journey.';
  END IF;

  v_reported_delay := greatest(0, floor(extract(epoch FROM (p_reported_arrival_at-v_scheduled))/60)::integer);
  v_percent := CASE WHEN v_reported_delay < 30 THEN 0 WHEN v_reported_delay < 60 THEN 25 WHEN v_reported_delay < 120 THEN 50 ELSE 100 END;
  IF v_percent=0 THEN RAISE EXCEPTION 'The reported arrival is less than 30 minutes late and does not qualify for compensation.'; END IF;
  v_amount := round(COALESCE(v_booking.total_fare,0)*v_percent/100.0,2);
  IF v_amount <= 0 THEN RAISE EXCEPTION 'The calculated compensation estimate is invalid.'; END IF;

  INSERT INTO public.delay_compensation_requests
    (incident_id,booking_id,user_id,booking_reference,original_fare,
     compensation_percent,compensation_amount,request_status,scheduled_arrival_at,
     reported_arrival_at,reported_delay_minutes)
  VALUES (NULL,v_booking.booking_id,v_user,v_booking.booking_reference,v_booking.total_fare,
          v_percent,v_amount,'pending',v_scheduled,p_reported_arrival_at,v_reported_delay)
  RETURNING request_id INTO v_request_id;

  INSERT INTO public.user_notifications(user_id,booking_id,title,message,notification_type)
  VALUES(v_user,v_booking.booking_id,'Delay compensation request submitted',
    'Your reported arrival time has been sent to Admin for verification. No JCoins have been credited yet.','info');

  RETURN jsonb_build_object('request_id',v_request_id,'status','pending',
    'compensation_percent',v_percent,'compensation_amount',v_amount,
    'reported_delay_minutes',v_reported_delay,
    'message','Your request has been submitted. Admin will verify the actual arrival time before deciding.');
EXCEPTION WHEN unique_violation THEN
  RAISE EXCEPTION 'A delay compensation request has already been submitted for this booking.';
END;
$function$;

DROP FUNCTION IF EXISTS public.review_delay_compensation_request(bigint,text,text);
CREATE OR REPLACE FUNCTION public.review_delay_compensation_request(
  p_request_id bigint,
  p_decision text,
  p_verified_actual_arrival_at timestamptz DEFAULT NULL,
  p_admin_note text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $function$
DECLARE
  v_role text := public.current_user_role()::text;
  v_req public.delay_compensation_requests%ROWTYPE;
  v_booking public.bookings%ROWTYPE;
  v_scheduled timestamptz;
  v_delay integer;
  v_percent numeric(5,2);
  v_amount numeric(12,2);
  v_balance numeric(12,2);
  v_tx bigint;
  v_incident_id bigint;
BEGIN
  IF COALESCE(v_role,'') NOT IN ('admin','super_admin') THEN
    RAISE EXCEPTION 'Only Admin or Super Admin can review compensation requests.';
  END IF;
  IF lower(COALESCE(p_decision,'')) NOT IN ('approved','rejected') THEN
    RAISE EXCEPTION 'Decision must be approved or rejected.';
  END IF;

  SELECT * INTO v_req FROM public.delay_compensation_requests WHERE request_id=p_request_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Compensation request not found.'; END IF;
  IF v_req.request_status <> 'pending' THEN RAISE EXCEPTION 'This request has already been reviewed.'; END IF;

  IF lower(p_decision)='rejected' THEN
    UPDATE public.delay_compensation_requests
       SET request_status='rejected',reviewed_by=auth.uid(),reviewed_at=now(),admin_note=NULLIF(btrim(p_admin_note),'')
     WHERE request_id=p_request_id;
    INSERT INTO public.user_notifications(user_id,booking_id,title,message,notification_type)
    VALUES(v_req.user_id,v_req.booking_id,'Delay compensation request declined',
      'Your delay compensation request was not approved. No JCoins were credited.','warning');
    RETURN jsonb_build_object('request_id',p_request_id,'status','rejected','credited',false);
  END IF;

  IF p_verified_actual_arrival_at IS NULL THEN RAISE EXCEPTION 'Enter the verified actual arrival date and time before approval.'; END IF;
  SELECT * INTO v_booking FROM public.bookings WHERE booking_id=v_req.booking_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'The linked booking could not be found.'; END IF;

  v_scheduled := v_req.scheduled_arrival_at;
  v_delay := greatest(0,floor(extract(epoch FROM (p_verified_actual_arrival_at-v_scheduled))/60)::integer);
  v_percent := CASE WHEN v_delay < 30 THEN 0 WHEN v_delay < 60 THEN 25 WHEN v_delay < 120 THEN 50 ELSE 100 END;
  IF v_percent=0 THEN RAISE EXCEPTION 'The verified arrival is less than 30 minutes late. Reject this request instead of approving it.'; END IF;
  v_amount := round(v_req.original_fare*v_percent/100.0,2);
  IF v_amount <= 0 THEN RAISE EXCEPTION 'The verified compensation amount is invalid.'; END IF;

  INSERT INTO public.train_delay_incidents
    (train_id,travel_date,arrival_station_id,actual_arrival_at,delay_minutes,compensation_percent,recorded_by)
  VALUES (v_booking.train_id,v_booking.travel_date,v_booking.arrival_station_id,
          p_verified_actual_arrival_at,v_delay,v_percent,auth.uid())
  ON CONFLICT (train_id,travel_date,arrival_station_id) DO UPDATE
    SET actual_arrival_at=EXCLUDED.actual_arrival_at,delay_minutes=EXCLUDED.delay_minutes,
        compensation_percent=EXCLUDED.compensation_percent,recorded_by=EXCLUDED.recorded_by,recorded_at=now()
  RETURNING incident_id INTO v_incident_id;

  UPDATE public.delay_compensation_requests
     SET incident_id=v_incident_id,verified_actual_arrival_at=p_verified_actual_arrival_at,
         verified_delay_minutes=v_delay,compensation_percent=v_percent,compensation_amount=v_amount,
         request_status='approved',reviewed_by=auth.uid(),reviewed_at=now(),admin_note=NULLIF(btrim(p_admin_note),'')
   WHERE request_id=p_request_id;

  INSERT INTO public.jcoins_wallets(user_id) VALUES(v_req.user_id) ON CONFLICT(user_id) DO NOTHING;
  SELECT balance INTO v_balance FROM public.jcoins_wallets WHERE user_id=v_req.user_id FOR UPDATE;
  v_balance := v_balance + v_amount;
  UPDATE public.jcoins_wallets SET balance=v_balance,total_earned=total_earned+v_amount,updated_at=now()
   WHERE user_id=v_req.user_id;

  INSERT INTO public.jcoins_transactions
    (user_id,transaction_type,direction,amount,balance_after,booking_id,booking_reference,description,idempotency_key,created_by)
  VALUES (v_req.user_id,'DELAY_COMPENSATION','credit',v_amount,v_balance,v_req.booking_id,v_req.booking_reference,
    'Admin-approved delay compensation based on verified arrival ('||v_percent::text||'%).',
    'delay-compensation-request:'||v_req.request_id::text,auth.uid())
  RETURNING transaction_id INTO v_tx;

  INSERT INTO public.user_notifications(user_id,booking_id,title,message,notification_type)
  VALUES(v_req.user_id,v_req.booking_id,'Delay compensation approved',
    v_amount::text||' JCoins have been credited to your wallet.','success');

  RETURN jsonb_build_object('request_id',p_request_id,'status','approved','credited',true,
    'amount',v_amount,'compensation_percent',v_percent,'verified_delay_minutes',v_delay,
    'jcoins_balance',v_balance,'transaction_id',v_tx);
END;
$function$;

REVOKE ALL ON FUNCTION public.request_delay_compensation(text,timestamptz) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.request_delay_compensation(text,timestamptz) TO authenticated;
REVOKE ALL ON FUNCTION public.review_delay_compensation_request(bigint,text,timestamptz,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.review_delay_compensation_request(bigint,text,timestamptz,text) TO authenticated;

COMMENT ON FUNCTION public.request_delay_compensation(text,timestamptz) IS
  'Passenger submits an optional reported actual arrival timestamp; it is not trusted until Admin verification.';
COMMENT ON FUNCTION public.review_delay_compensation_request(bigint,text,timestamptz,text) IS
  'Admin verifies actual arrival and approves/rejects; wallet credit occurs only after approval.';

COMMIT;

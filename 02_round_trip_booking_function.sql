-- JJCC Railways Round Trip migration - split execution
-- Part 2 of 3: create_round_trip_booking_with_seats RPC and permissions. Run after Part 1.
-- Run this file as one complete query in Supabase SQL Editor.

BEGIN;

-- Creates one parent booking and attaches a separately selected return train
-- and return seat assignments to that same booking reference. The existing
-- one-way RPC remains unchanged.
CREATE OR REPLACE FUNCTION public.create_round_trip_booking_with_seats(
  p_outbound_train_code text,
  p_outbound_departure_code text,
  p_outbound_arrival_code text,
  p_outbound_travel_date date,
  p_total_passengers integer,
  p_outbound_passengers jsonb,
  p_return_train_code text,
  p_return_departure_code text,
  p_return_arrival_code text,
  p_return_travel_date date,
  p_return_passengers jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_user_id uuid := auth.uid();
  v_outbound_train_id bigint;
  v_outbound_total_seats integer;
  v_return_train_id bigint;
  v_return_total_seats integer;
  v_lock_key_a text;
  v_lock_key_b text;
  v_return_departure_station_id bigint;
  v_return_arrival_station_id bigint;
  v_return_departure_order integer;
  v_return_arrival_order integer;
  v_return_departure_time time;
  v_return_arrival_time time;
  v_return_segment_count integer;
  v_return_priced_segment_count integer;
  v_return_unit_fare numeric(10,2);
  v_existing_passengers integer;
  v_item jsonb;
  v_outbound_item jsonb;
  v_seat_number text;
  v_seat_id bigint;
  v_requested_seats text[] := ARRAY[]::text[];
  v_reserved_outbound_seats text[] := ARRAY[]::text[];
  v_booking_result jsonb;
  v_booking_id bigint;
  v_booking_reference text;
  v_passenger_id bigint;
  v_index integer := 0;
  v_return_saved jsonb := '[]'::jsonb;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Please sign in before booking.';
  END IF;

  IF p_total_passengers IS NULL OR p_total_passengers < 1 OR p_total_passengers > 9 THEN
    RAISE EXCEPTION 'Passenger count must be between 1 and 9.';
  END IF;

  IF p_outbound_passengers IS NULL
     OR pg_catalog.jsonb_typeof(p_outbound_passengers) <> 'array'
     OR pg_catalog.jsonb_array_length(p_outbound_passengers) <> p_total_passengers
     OR p_return_passengers IS NULL
     OR pg_catalog.jsonb_typeof(p_return_passengers) <> 'array'
     OR pg_catalog.jsonb_array_length(p_return_passengers) <> p_total_passengers THEN
    RAISE EXCEPTION 'Passenger information must contain one outbound and one return seat for every passenger.';
  END IF;

  IF p_return_travel_date IS NULL
     OR p_return_travel_date < p_outbound_travel_date
     OR p_return_travel_date < (pg_catalog.now() AT TIME ZONE 'Asia/Manila')::date THEN
    RAISE EXCEPTION 'Please select a valid return date.';
  END IF;

  IF pg_catalog.upper(pg_catalog.btrim(p_return_departure_code))
       <> pg_catalog.upper(pg_catalog.btrim(p_outbound_arrival_code))
     OR pg_catalog.upper(pg_catalog.btrim(p_return_arrival_code))
       <> pg_catalog.upper(pg_catalog.btrim(p_outbound_departure_code)) THEN
    RAISE EXCEPTION 'The return route must reverse the outbound stations.';
  END IF;

  SELECT t.train_id, t.total_seats
    INTO v_outbound_train_id, v_outbound_total_seats
    FROM public.trains t
   WHERE t.train_code = pg_catalog.upper(pg_catalog.btrim(p_outbound_train_code))
     AND t.is_active = true;

  IF v_outbound_train_id IS NULL THEN
    RAISE EXCEPTION 'Outbound train not found or inactive.';
  END IF;

  SELECT t.train_id, t.total_seats
    INTO v_return_train_id, v_return_total_seats
    FROM public.trains t
   WHERE t.train_code = pg_catalog.upper(pg_catalog.btrim(p_return_train_code))
     AND t.is_active = true;

  IF v_return_train_id IS NULL THEN
    RAISE EXCEPTION 'Return train not found or inactive.';
  END IF;

  -- Lock both train/date pairs in deterministic lexical order to reduce deadlocks.
  v_lock_key_a := v_outbound_train_id::text || ':' || p_outbound_travel_date::text;
  v_lock_key_b := v_return_train_id::text || ':' || p_return_travel_date::text;
  IF v_lock_key_a <= v_lock_key_b THEN
    PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(v_lock_key_a, 0));
    IF v_lock_key_b <> v_lock_key_a THEN
      PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(v_lock_key_b, 0));
    END IF;
  ELSE
    PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(v_lock_key_b, 0));
    PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(v_lock_key_a, 0));
  END IF;

  -- Count outbound bookings plus return-leg seats already using the outbound train.
  SELECT
    COALESCE((SELECT SUM(b.total_passengers)::integer
                FROM public.bookings b
               WHERE b.train_id = v_outbound_train_id
                 AND b.travel_date = p_outbound_travel_date
                 AND pg_catalog.lower(b.booking_status) NOT IN ('cancelled','refunded','expired')), 0)
    +
    COALESCE((SELECT COUNT(*)::integer
                FROM public.booking_return_passengers brp
                JOIN public.bookings b ON b.booking_id = brp.booking_id
               WHERE b.return_train_id = v_outbound_train_id
                 AND b.return_travel_date = p_outbound_travel_date
                 AND pg_catalog.lower(b.booking_status) NOT IN ('cancelled','refunded','expired')), 0)
    INTO v_existing_passengers;

  -- Do not allow an outbound seat to collide with an existing return-leg seat.
  SELECT COALESCE(pg_catalog.array_agg(r.seat_number), ARRAY[]::text[])
    INTO v_reserved_outbound_seats
    FROM public.get_round_trip_reserved_seats(
      p_outbound_train_code,
      p_outbound_departure_code,
      p_outbound_arrival_code,
      p_outbound_travel_date
    ) r;

  IF v_existing_passengers + p_total_passengers > v_outbound_total_seats THEN
    RAISE EXCEPTION 'Not enough train capacity on the selected outbound train.';
  END IF;

  FOR v_item IN SELECT value FROM pg_catalog.jsonb_array_elements(p_outbound_passengers)
  LOOP
    v_seat_number := pg_catalog.btrim(v_item ->> 'seat_number');
    IF v_seat_number = ANY(v_reserved_outbound_seats) THEN
      RAISE EXCEPTION 'Outbound seat % is already reserved for a return journey.', v_seat_number;
    END IF;
  END LOOP;

  -- Resolve and validate the return journey schedule.
  SELECT ts.stop_order, ts.departure_time, s.station_id
    INTO v_return_departure_order, v_return_departure_time, v_return_departure_station_id
    FROM public.train_stops ts
    JOIN public.stations s ON s.station_id = ts.station_id
   WHERE ts.train_id = v_return_train_id
     AND s.station_code = pg_catalog.upper(pg_catalog.btrim(p_return_departure_code))
     AND s.is_active = true;

  IF NOT FOUND OR v_return_departure_time IS NULL THEN
    RAISE EXCEPTION 'Invalid return departure station or schedule.';
  END IF;

  SELECT ts.stop_order, ts.arrival_time, s.station_id
    INTO v_return_arrival_order, v_return_arrival_time, v_return_arrival_station_id
    FROM public.train_stops ts
    JOIN public.stations s ON s.station_id = ts.station_id
   WHERE ts.train_id = v_return_train_id
     AND s.station_code = pg_catalog.upper(pg_catalog.btrim(p_return_arrival_code))
     AND s.is_active = true;

  IF NOT FOUND OR v_return_arrival_time IS NULL
     OR v_return_arrival_order <= v_return_departure_order THEN
    RAISE EXCEPTION 'Invalid return arrival station or route direction.';
  END IF;

  SELECT COUNT(*)::integer,
         COUNT(ts.fare_from_previous)::integer,
         COALESCE(SUM(ts.fare_from_previous), 0)::numeric(10,2)
    INTO v_return_segment_count, v_return_priced_segment_count, v_return_unit_fare
    FROM public.train_stops ts
   WHERE ts.train_id = v_return_train_id
     AND ts.stop_order > v_return_departure_order
     AND ts.stop_order <= v_return_arrival_order;

  IF v_return_segment_count = 0 OR v_return_segment_count <> v_return_priced_segment_count THEN
    RAISE EXCEPTION 'Return fare information is incomplete.';
  END IF;

  -- Capacity includes both existing outbound reservations and existing return seats.
  SELECT
    COALESCE((SELECT SUM(b.total_passengers)::integer
                FROM public.bookings b
               WHERE b.train_id = v_return_train_id
                 AND b.travel_date = p_return_travel_date
                 AND pg_catalog.lower(b.booking_status) NOT IN ('cancelled','refunded','expired')), 0)
    +
    COALESCE((SELECT COUNT(*)::integer
                FROM public.booking_return_passengers brp
                JOIN public.bookings b ON b.booking_id = brp.booking_id
               WHERE b.return_train_id = v_return_train_id
                 AND b.return_travel_date = p_return_travel_date
                 AND pg_catalog.lower(b.booking_status) NOT IN ('cancelled','refunded','expired')), 0)
    INTO v_existing_passengers;

  IF v_existing_passengers + p_total_passengers > v_return_total_seats THEN
    RAISE EXCEPTION 'Not enough capacity on the selected return train.';
  END IF;

  -- Validate each return seat, including overlaps with outbound and return bookings.
  FOR v_item IN SELECT value FROM pg_catalog.jsonb_array_elements(p_return_passengers)
  LOOP
    v_seat_number := pg_catalog.btrim(v_item ->> 'seat_number');

    IF v_seat_number IS NULL OR v_seat_number !~ '^[A-Z0-9]+-[0-9]{2}$' THEN
      RAISE EXCEPTION 'Invalid return seat number format.';
    END IF;

    IF v_seat_number = ANY(v_requested_seats) THEN
      RAISE EXCEPTION 'Two passengers cannot use the same return seat.';
    END IF;

    v_requested_seats := pg_catalog.array_append(v_requested_seats, v_seat_number);

    SELECT s.seat_id INTO v_seat_id
      FROM public.train_seats s
     WHERE s.train_id = v_return_train_id
       AND s.coach_code || '-' || s.seat_number = v_seat_number
       AND s.is_active = true;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'Selected return seat % does not exist on this train.', v_seat_number;
    END IF;

    IF EXISTS (
      SELECT 1
        FROM public.booking_passengers bp
        JOIN public.bookings b ON b.booking_id = bp.booking_id
        JOIN public.train_stops booked_from
          ON booked_from.train_id = b.train_id
         AND booked_from.station_id = b.departure_station_id
        JOIN public.train_stops booked_to
          ON booked_to.train_id = b.train_id
         AND booked_to.station_id = b.arrival_station_id
       WHERE b.train_id = v_return_train_id
         AND b.travel_date = p_return_travel_date
         AND pg_catalog.lower(b.booking_status) NOT IN ('cancelled','refunded','expired')
         AND bp.seat_number = v_seat_number
         AND booked_from.stop_order < v_return_arrival_order
         AND booked_to.stop_order > v_return_departure_order
    ) THEN
      RAISE EXCEPTION 'Return seat % is already occupied. Please select another seat.', v_seat_number;
    END IF;

    IF EXISTS (
      SELECT 1
        FROM public.booking_return_passengers brp
        JOIN public.bookings b ON b.booking_id = brp.booking_id
        JOIN public.train_stops booked_from
          ON booked_from.train_id = b.return_train_id
         AND booked_from.station_id = b.return_departure_station_id
        JOIN public.train_stops booked_to
          ON booked_to.train_id = b.return_train_id
         AND booked_to.station_id = b.return_arrival_station_id
       WHERE b.return_train_id = v_return_train_id
         AND b.return_travel_date = p_return_travel_date
         AND pg_catalog.lower(b.booking_status) NOT IN ('cancelled','refunded','expired')
         AND brp.seat_number = v_seat_number
         AND booked_from.stop_order < v_return_arrival_order
         AND booked_to.stop_order > v_return_departure_order
    ) THEN
      RAISE EXCEPTION 'Return seat % is already reserved. Please select another seat.', v_seat_number;
    END IF;
  END LOOP;

  -- Create the outbound booking using the existing, fully validated one-way RPC.
  v_booking_result := public.create_booking_with_seats(
    p_outbound_train_code,
    p_outbound_departure_code,
    p_outbound_arrival_code,
    p_outbound_travel_date,
    p_total_passengers,
    p_outbound_passengers
  );

  v_booking_id := (v_booking_result ->> 'booking_id')::bigint;
  v_booking_reference := v_booking_result ->> 'booking_reference';

  IF v_booking_id IS NULL OR v_booking_reference IS NULL THEN
    RAISE EXCEPTION 'The outbound booking could not be created.';
  END IF;

  -- Store the return service on the same booking row, preserving one reference
  -- and one payment. total_fare becomes outbound + return for all passengers.
  UPDATE public.bookings
     SET trip_type = 'round_trip',
         return_train_id = v_return_train_id,
         return_departure_station_id = v_return_departure_station_id,
         return_arrival_station_id = v_return_arrival_station_id,
         return_travel_date = p_return_travel_date,
         return_departure_time = v_return_departure_time,
         return_arrival_time = v_return_arrival_time,
         return_fare = v_return_unit_fare,
         total_fare = total_fare + (v_return_unit_fare * p_total_passengers)
   WHERE booking_id = v_booking_id;

  -- Link each return seat to the same passenger record used by the outbound leg.
  FOR v_item IN
    SELECT value
      FROM pg_catalog.jsonb_array_elements(v_booking_result -> 'passengers')
  LOOP
    v_index := v_index + 1;
    v_passenger_id := (v_item ->> 'passenger_id')::bigint;
    v_outbound_item := p_return_passengers -> (v_index - 1);
    v_seat_number := pg_catalog.btrim(v_outbound_item ->> 'seat_number');

    IF pg_catalog.btrim(v_item ->> 'full_name')
       IS DISTINCT FROM pg_catalog.btrim(v_outbound_item ->> 'full_name') THEN
      RAISE EXCEPTION 'Return passenger order/details must match the outbound passenger list.';
    END IF;

    INSERT INTO public.booking_return_passengers(booking_id, passenger_id, seat_number)
    VALUES (v_booking_id, v_passenger_id, v_seat_number);

    v_return_saved := v_return_saved || pg_catalog.jsonb_build_array(
      pg_catalog.jsonb_build_object(
        'passenger_id', v_passenger_id,
        'full_name', v_item ->> 'full_name',
        'passenger_type', v_item ->> 'passenger_type',
        'seat_number', v_seat_number
      )
    );
  END LOOP;

  RETURN pg_catalog.jsonb_build_object(
    'booking_id', v_booking_id,
    'booking_reference', v_booking_reference,
    'booking_status', 'pending_payment',
    'trip_type', 'round_trip',
    'train_code', v_booking_result ->> 'train_code',
    'departure_time', v_booking_result ->> 'departure_time',
    'arrival_time', v_booking_result ->> 'arrival_time',
    'total_passengers', p_total_passengers,
    'total_fare', (v_booking_result ->> 'total_fare')::numeric + (v_return_unit_fare * p_total_passengers),
    'passengers', v_booking_result -> 'passengers',
    'return_train_code', pg_catalog.upper(pg_catalog.btrim(p_return_train_code)),
    'return_departure_time', v_return_departure_time,
    'return_arrival_time', v_return_arrival_time,
    'return_travel_date', p_return_travel_date,
    'return_fare', v_return_unit_fare,
    'return_passengers', v_return_saved
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.create_round_trip_booking_with_seats(
  text, text, text, date, integer, jsonb, text, text, text, date, jsonb
) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.create_round_trip_booking_with_seats(
  text, text, text, date, integer, jsonb, text, text, text, date, jsonb
) TO authenticated;

COMMIT;

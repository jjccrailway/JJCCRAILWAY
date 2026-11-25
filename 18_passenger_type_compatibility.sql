-- JJCC Railways: Passenger type compatibility patch
-- Run AFTER SQL 15A-15D and SQL 16-17 have been successfully applied.
-- This replaces the legacy one-way booking RPC so it accepts the current
-- passenger types used by the discount workflow: regular, student, senior, pwd.
-- The existing round-trip RPC (15C) calls this one-way RPC for the outbound leg.

BEGIN;

ALTER TABLE public.passengers
  ALTER COLUMN passenger_type SET DEFAULT 'regular';

CREATE OR REPLACE FUNCTION public.create_booking_with_seats(p_train_code text, p_departure_code text, p_arrival_code text, p_travel_date date, p_total_passengers integer, p_passengers jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$

DECLARE
    v_user_id UUID := auth.uid();

    v_train_id BIGINT;
    v_total_seats INTEGER;

    v_departure_station_id BIGINT;
    v_arrival_station_id BIGINT;

    v_departure_order INTEGER;
    v_arrival_order INTEGER;

    v_departure_time TIME;
    v_arrival_time TIME;

    v_segment_count INTEGER;
    v_priced_segment_count INTEGER;

    v_unit_fare NUMERIC(10,2);

    v_booked_passengers INTEGER;

    v_booking_id BIGINT;
    v_booking_reference TEXT;

    v_passenger JSONB;
    v_full_name TEXT;
    v_age INTEGER;
    v_passenger_type TEXT;

    v_seat_number TEXT;
    v_seat_id BIGINT;

    v_passenger_id BIGINT;

    v_requested_seats TEXT[] := ARRAY[]::TEXT[];
    v_saved_passengers JSONB := '[]'::JSONB;

    v_passenger_count INTEGER := 0;

BEGIN

    -- =================================================
    -- 1. AUTHENTICATION
    -- =================================================

    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'Please sign in before booking.';
    END IF;


    -- =================================================
    -- 2. VALIDATE PASSENGER COUNT AND INFORMATION
    -- =================================================

    IF p_total_passengers IS NULL
       OR p_total_passengers < 1
       OR p_total_passengers > 9 THEN

        RAISE EXCEPTION
            'Passenger count must be between 1 and 9.';
    END IF;

    IF p_passengers IS NULL
       OR pg_catalog.jsonb_typeof(p_passengers) <> 'array'
       OR pg_catalog.jsonb_array_length(p_passengers)
          <> p_total_passengers THEN

        RAISE EXCEPTION
            'Passenger information does not match passenger count.';
    END IF;


    -- =================================================
    -- 3. VALIDATE TRAVEL DATE
    -- =================================================

    IF p_travel_date IS NULL
       OR p_travel_date <
          (pg_catalog.now() AT TIME ZONE 'Asia/Manila')::DATE THEN

        RAISE EXCEPTION
            'Please select a valid travel date.';
    END IF;


    -- =================================================
    -- 4. FIND ACTIVE TRAIN
    -- =================================================

    SELECT
        t.train_id,
        t.total_seats

    INTO
        v_train_id,
        v_total_seats

    FROM public.trains t

    WHERE t.train_code =
        pg_catalog.upper(pg_catalog.btrim(p_train_code))

      AND t.is_active = TRUE;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'Train not found or inactive.';
    END IF;


    -- =================================================
    -- 5. LOCK TRAIN AND TRAVEL DATE
    -- Prevent simultaneous seat assignment requests.
    -- =================================================

    PERFORM pg_catalog.pg_advisory_xact_lock(
        pg_catalog.hashtextextended(
            v_train_id::TEXT || ':' || p_travel_date::TEXT,
            0
        )
    );


    -- =================================================
    -- 6. FIND DEPARTURE STATION
    -- =================================================

    SELECT
        ts.stop_order,
        ts.departure_time,
        s.station_id

    INTO
        v_departure_order,
        v_departure_time,
        v_departure_station_id

    FROM public.train_stops ts

    JOIN public.stations s
        ON s.station_id = ts.station_id

    WHERE ts.train_id = v_train_id

      AND s.station_code =
          pg_catalog.upper(pg_catalog.btrim(p_departure_code))

      AND s.is_active = TRUE;

    IF NOT FOUND OR v_departure_time IS NULL THEN
        RAISE EXCEPTION
            'Invalid departure station.';
    END IF;


    -- =================================================
    -- 7. FIND ARRIVAL STATION
    -- =================================================

    SELECT
        ts.stop_order,
        ts.arrival_time,
        s.station_id

    INTO
        v_arrival_order,
        v_arrival_time,
        v_arrival_station_id

    FROM public.train_stops ts

    JOIN public.stations s
        ON s.station_id = ts.station_id

    WHERE ts.train_id = v_train_id

      AND s.station_code =
          pg_catalog.upper(pg_catalog.btrim(p_arrival_code))

      AND s.is_active = TRUE;

    IF NOT FOUND OR v_arrival_time IS NULL THEN
        RAISE EXCEPTION
            'Invalid arrival station.';
    END IF;


    -- =================================================
    -- 8. VALIDATE ROUTE DIRECTION
    -- =================================================

    IF v_arrival_order <= v_departure_order THEN
        RAISE EXCEPTION
            'Invalid route direction.';
    END IF;


    -- =================================================
    -- 9. CALCULATE FARE FROM DATABASE
    -- =================================================

    SELECT
        COUNT(*)::INTEGER,

        COUNT(ts.fare_from_previous)::INTEGER,

        COALESCE(
            SUM(ts.fare_from_previous),
            0
        )::NUMERIC(10,2)

    INTO
        v_segment_count,
        v_priced_segment_count,
        v_unit_fare

    FROM public.train_stops ts

    WHERE ts.train_id = v_train_id

      AND ts.stop_order > v_departure_order

      AND ts.stop_order <= v_arrival_order;


    IF v_segment_count = 0
       OR v_segment_count <> v_priced_segment_count THEN

        RAISE EXCEPTION
            'Fare information is incomplete.';
    END IF;


    -- =================================================
    -- 10. CHECK TOTAL TRAIN CAPACITY
    -- =================================================

    SELECT
        COALESCE(
            SUM(b.total_passengers),
            0
        )::INTEGER

    INTO v_booked_passengers

    FROM public.bookings b

    WHERE b.train_id = v_train_id

      AND b.travel_date = p_travel_date

      AND pg_catalog.lower(b.booking_status)
          NOT IN ('cancelled', 'refunded', 'expired');


    IF v_booked_passengers + p_total_passengers
       > v_total_seats THEN

        RAISE EXCEPTION
            'Not enough train capacity.';
    END IF;


    -- =================================================
    -- 11. VALIDATE SELECTED SEATS
    -- =================================================

    FOR v_passenger IN

        SELECT value

        FROM pg_catalog.jsonb_array_elements(p_passengers)

    LOOP

        v_full_name :=
            pg_catalog.btrim(v_passenger ->> 'full_name');

        v_seat_number :=
            pg_catalog.btrim(v_passenger ->> 'seat_number');


        -- Validate passenger name

        IF v_full_name IS NULL
           OR v_full_name = ''
           OR pg_catalog.length(v_full_name) > 150 THEN

            RAISE EXCEPTION
                'Each passenger must have a valid full name.';
        END IF;


        -- Validate seat format

        IF v_seat_number IS NULL
           OR v_seat_number !~ '^[A-Z0-9]+-[0-9]{2}$' THEN

            RAISE EXCEPTION
                'Invalid seat number format.';
        END IF;


        -- Prevent duplicate seats in the same booking

        IF v_seat_number = ANY(v_requested_seats) THEN

            RAISE EXCEPTION
                'Two passengers cannot use the same seat.';
        END IF;


        v_requested_seats :=
            pg_catalog.array_append(
                v_requested_seats,
                v_seat_number
            );


        -- Check if seat belongs to this train

        SELECT
            s.seat_id

        INTO v_seat_id

        FROM public.train_seats s

        WHERE s.train_id = v_train_id

          AND s.coach_code || '-' || s.seat_number =
              v_seat_number

          AND s.is_active = TRUE;


        IF NOT FOUND THEN
            RAISE EXCEPTION
                'Selected seat does not exist on this train.';
        END IF;


        -- Check overlapping seat reservations

        IF EXISTS (

            SELECT 1

            FROM public.booking_passengers bp

            JOIN public.bookings b
                ON b.booking_id = bp.booking_id

            JOIN public.train_stops booked_from
                ON booked_from.train_id = b.train_id

               AND booked_from.station_id =
                   b.departure_station_id

            JOIN public.train_stops booked_to
                ON booked_to.train_id = b.train_id

               AND booked_to.station_id =
                   b.arrival_station_id

            WHERE b.train_id = v_train_id

              AND b.travel_date = p_travel_date

              AND pg_catalog.lower(b.booking_status)
                  NOT IN ('cancelled', 'refunded', 'expired')

              AND bp.seat_number = v_seat_number

              AND booked_from.stop_order < v_arrival_order

              AND booked_to.stop_order > v_departure_order

        ) THEN

            RAISE EXCEPTION
                'Seat % is already occupied. Please select another seat.',
                v_seat_number;

        END IF;

    END LOOP;


    -- =================================================
    -- 12. GENERATE UNIQUE BOOKING REFERENCE
    -- =================================================

    LOOP

        v_booking_reference :=

            'JRC-' ||

            pg_catalog.upper(
                pg_catalog.substr(
                    pg_catalog.replace(
                        pg_catalog.gen_random_uuid()::TEXT,
                        '-',
                        ''
                    ),
                    1,
                    4
                )
            ) ||

            '-' ||

            pg_catalog.upper(
                pg_catalog.substr(
                    pg_catalog.replace(
                        pg_catalog.gen_random_uuid()::TEXT,
                        '-',
                        ''
                    ),
                    1,
                    3
                )
            );


        EXIT WHEN NOT EXISTS (

            SELECT 1

            FROM public.bookings b

            WHERE b.booking_reference =
                v_booking_reference

        );

    END LOOP;


    -- =================================================
    -- 13. CREATE BOOKING
    -- =================================================

    INSERT INTO public.bookings (

        user_id,
        booking_reference,
        train_id,

        departure_station_id,
        arrival_station_id,

        travel_date,

        departure_time,
        arrival_time,

        total_passengers,
        total_fare,

        booking_status

    )

    VALUES (

        v_user_id,
        v_booking_reference,
        v_train_id,

        v_departure_station_id,
        v_arrival_station_id,

        p_travel_date,

        v_departure_time,
        v_arrival_time,

        p_total_passengers,
        v_unit_fare * p_total_passengers,

        'confirmed'

    )

    RETURNING booking_id
    INTO v_booking_id;


    -- =================================================
    -- 14. SAVE PASSENGER DETAILS AND SEATS
    -- =================================================

    FOR v_passenger IN

        SELECT value

        FROM pg_catalog.jsonb_array_elements(p_passengers)

    LOOP

        v_full_name :=
            pg_catalog.btrim(v_passenger ->> 'full_name');


        v_seat_number :=
            pg_catalog.btrim(v_passenger ->> 'seat_number');


        -- Validate age

        IF NULLIF(v_passenger ->> 'age', '') IS NULL THEN

            v_age := NULL;

        ELSE

            IF (v_passenger ->> 'age') !~ '^[0-9]{1,3}$' THEN

                RAISE EXCEPTION
                    'Invalid passenger age.';

            END IF;

            v_age :=
                (v_passenger ->> 'age')::INTEGER;

            IF v_age < 0 OR v_age > 120 THEN

                RAISE EXCEPTION
                    'Passenger age must be between 0 and 120.';

            END IF;

        END IF;


        -- Validate passenger type

        v_passenger_type :=

            COALESCE(

                NULLIF(

                    pg_catalog.lower(
                        pg_catalog.btrim(
                            v_passenger ->> 'passenger_type'
                        )
                    ),

                    ''

                ),

                'regular'

            );


        IF v_passenger_type NOT IN (
            'regular',
            'student',
            'senior',
            'pwd'
        ) THEN

            RAISE EXCEPTION
                'Invalid passenger type.';

        END IF;


        -- Insert passenger

        INSERT INTO public.passengers (

            user_id,
            full_name,
            age,
            passenger_type

        )

        VALUES (

            v_user_id,
            v_full_name,
            v_age,
            v_passenger_type

        )

        RETURNING passenger_id
        INTO v_passenger_id;


        -- Link passenger to booking and assign seat

        INSERT INTO public.booking_passengers (

            booking_id,
            passenger_id,
            seat_number

        )

        VALUES (

            v_booking_id,
            v_passenger_id,
            v_seat_number

        );


        -- Prepare passenger confirmation data

        v_saved_passengers :=

            v_saved_passengers ||

            pg_catalog.jsonb_build_array(

                pg_catalog.jsonb_build_object(

                    'passenger_id',
                    v_passenger_id,

                    'full_name',
                    v_full_name,

                    'age',
                    v_age,

                    'passenger_type',
                    v_passenger_type,

                    'seat_number',
                    v_seat_number

                )

            );


        v_passenger_count :=
            v_passenger_count + 1;

    END LOOP;


    -- =================================================
    -- 15. RETURN BOOKING CONFIRMATION
    -- =================================================

    RETURN pg_catalog.jsonb_build_object(

        'booking_id',
        v_booking_id,

        'booking_reference',
        v_booking_reference,

        'train_code',
        p_train_code,

        'departure_time',
        v_departure_time,

        'arrival_time',
        v_arrival_time,

        'total_passengers',
        v_passenger_count,

        'total_fare',
        v_unit_fare * p_total_passengers,

        'booking_status',
        'confirmed',

        'passengers',
        v_saved_passengers

    );

END;

$function$;

COMMIT;

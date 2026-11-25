-- OPTIONAL scheduler setup. Run only after enabling pg_cron in Supabase.
-- Existing migration 02 schedules expire_pending_bookings(); this adds per-passenger expiry.
CREATE EXTENSION IF NOT EXISTS pg_cron WITH SCHEMA pg_catalog;

SELECT cron.unschedule('jjcc-expire-passenger-payment-holds')
WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'jjcc-expire-passenger-payment-holds');

SELECT cron.schedule(
  'jjcc-expire-passenger-payment-holds',
  '* * * * *',
  $$SELECT public.expire_passenger_payment_holds();$$
);

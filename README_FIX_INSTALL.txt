JJCC RAILWAYS — ADMIN FINANCE & FARE FIX
========================================

This patch addresses the errors in the uploaded project:
1. Fare Management now uses the existing public.train_stops table, not the
   nonexistent public.station_stops table.
2. Fare reads and writes go through staff-only Supabase RPC functions.
3. Admin dashboard and Revenue & Transactions use a reconciled financial
   summary rather than treating bookings.paid_at as the only source of payment.
4. Financial totals include:
   - completed booking-level cash payments;
   - approved passenger-level cash receipts;
   - JCoins BOOKING_PAYMENT debits;
   - legacy confirmed paid bookings with no ledger record;
   - less REFUND_CREDIT entries;
   - less reversed JCoins payment debits (BOOKING_PAYMENT_REVERSAL).
5. Daily revenue chart uses recorded payment dates and displays weekday + date.
6. Staff notification / sign-out actions are placed inside the page header flow,
   not fixed over dashboard controls.
7. Administrator Information updates are null-safe.

INSTALLATION
------------
1. Back up your Supabase database and current project folder.
2. In Supabase SQL Editor, run:
   24_staff_financial_reporting_and_train_fares.sql
3. Copy the following files from this patch into the root of your existing
   JJCC_Railways_Updated project, replacing matching files:
   - admin.html
   - admin-theme.css
   - fare-management.html
   - finance.html
   - staff-dashboard.js
   - staff-shell.js
4. Hard-refresh the browser with Ctrl + Shift + R.
5. Test as an Admin and as a Super Admin:
   - Open Train Fare Management, change one segment fare, save, and refresh.
   - Create a NEW test booking to verify the changed segment price is used.
   - Verify an EXISTING booking still has its original saved total_fare.
   - Check Finance and Dashboard against completed booking_payments,
     approved passenger_payment_submissions, JCoins transactions and refunds.

IMPORTANT NOTES
---------------
- The migration deliberately uses the existing train_stops structure referenced
  by the project's passenger-fare calculation SQL. It does not create a second
  station-stop table.
- Existing bookings are not repriced by the fare update.
- Do not manually edit payment totals in the dashboard. The RPC calculates
  them from payment and JCoins records.
- If the migration reports a missing column/table, stop and send that exact
  Supabase error before applying any alternate schema changes.
- The project archive contains a php/.env file. Do not upload that file or
  private secrets to GitHub. Keep .env ignored and rotate any secret that was
  previously committed.

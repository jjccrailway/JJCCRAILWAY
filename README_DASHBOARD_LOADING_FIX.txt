JJCC RAILWAYS — DASHBOARD LOADING FIX
======================================

WHY THE DASHBOARD WAS FAILING
The previous financial-summary SQL used SUM() expressions inside
jsonb_agg(jsonb_build_object(...)), which PostgreSQL rejects with:
"aggregate function calls cannot be nested".

This patch fixes that by calculating daily totals in a separate grouped query,
then converting those daily rows to JSON.

PERFORMANCE / LOADING CHANGE
- Admin dashboard no longer calls get_staff_booking_records just to count
  bookings. It reads only booking_id and status fields directly from bookings.
- Dashboard error handling clears permanent Loading placeholders and shows
  an actionable message instead.
- The detailed booking/review pages are not changed.

INSTALL
1. Back up your project and Supabase database.
2. Run 24_staff_financial_reporting_and_train_fares.sql again in Supabase SQL
   Editor. It uses CREATE OR REPLACE, so it replaces the broken function.
3. Replace these files in the project root:
   - admin.html
   - staff-dashboard.js
   - admin-theme.css
   - finance.html
   - fare-management.html
   - staff-shell.js
4. Hard refresh (Ctrl + Shift + R).

TEST
- Open Admin Dashboard and press Refresh.
- Confirm Revenue Overview has date labels and bars.
- Confirm Booking Status loads.
- Open Revenue & Transactions and compare totals.
- Test as Super Admin as well.

IMPORTANT
- This patch does not alter passenger/User pages or booking workflows.
- If the dashboard still reports an error, copy the exact red error message.
- This patch has not been run against the live Supabase project from here.

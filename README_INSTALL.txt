JJCC RAILWAYS - UPDATED PAYMENT / BOOKING WORKFLOW

FILES
- Keep all HTML pages, script.js, style.css, JCC LOGO.png, and backgroundPic.png in the same website folder.
- New pages: payments.html (admin receipt review), notifications.html (user notifications), jcoins.html (JCoins wallet), and delay-operations.html (staff recording of verified actual train arrivals).
- New SQL migration: 04_receipt_payment_workflow.sql.

SUPABASE SQL ORDER
1. If the earlier payment/cancellation migration has NOT been run, run 01_payment_migration.sql first.
2. Run 04_receipt_payment_workflow.sql. This creates receipt and notification tables, a private Storage bucket, the 10-minute hold, admin approval/rejection, and train condition status. It also removes the earlier mock-payment RPC.
3. Run 05_cancellation_policy_fix.sql, then 08_combined_booking_modifications.sql, then 09_jcoins_wallet_foundation.sql and 10_jcoins_automatic_refunds_and_delay_compensation.sql. Then enable pg_cron in Supabase Database > Extensions and run 02_schedule_expiry.sql to expire unpaid reservations and unpaid modification requests every minute. The expiry function is restricted to service_role; the browser must not call it. If pg_cron is unavailable, configure a trusted server-side scheduled task using the service_role key (never expose that key in browser JavaScript).

IMPORTANT PAYMENT NOTE
The QR and bank details shown in payment.html are deliberately non-functional placeholders. They are not connected to a bank, wallet, QR payment provider, or real payment processor. Do not accept or transfer real money using them. Receipt upload and administrator approval are application workflow features only; a screenshot upload does not prove that money was received. For real payments, replace the placeholder details and add a verified payment-provider/server-side reconciliation process before using this with customers.

WORKFLOW
- A booking is created as pending_payment and seats are held for 10 minutes.
- The user uploads a receipt within the 10-minute window. The booking stays reserved while the receipt is pending admin review.
- Admins open payments.html, view the private receipt, then approve or reject it. Approval confirms the booking and creates an in-app notification. Rejection creates an in-app notification; the user may upload a corrected receipt if the original 10-minute deadline has not passed.
- If no receipt is uploaded before the deadline, the booking expires and its seats are released by expire_pending_bookings().
- Users open Notifications from the header to read approval/rejection updates.
- Manage Booking, Refund, and automatic Delay Compensation information are opened from the selected booking card in Active Bookings; the booking reference is passed automatically.
- Past confirmed journeys appear under Delivered; cancelled/expired journeys have their own tab; All Bookings shows the complete list.
- A paid booking can be cancelled immediately by the user within 24 hours after payment confirmation, measured from bookings.paid_at. Migration 10 credits 50% of the original fare to JCoins automatically. No administrator approval is required.

TRAIN STATUS
The migration adds public.trains.train_status with values active, broken, inactive. Admins can update this status in admin.html; the dashboard totals update from this field. Existing trains default to active.

TESTING
Run the website from your normal local server (for example VS Code Live Server). Sign in using real Supabase accounts with profiles.role set to admin or super_admin for the corresponding portals. Do not use sessionStorage role previews as security.


UPDATED CANCELLATION POLICY (05_cancellation_policy_fix.sql)
1. Back up the Supabase database first.
2. Confirm 01_payment_migration.sql and 04_receipt_payment_workflow.sql have already been run successfully.
3. Review 05_cancellation_policy_fix.sql before running it. Run it once in Supabase SQL Editor.
4. The 24-hour voluntary cancellation period starts when payment is confirmed and bookings.paid_at is set.
5. This historical migration's zero-refund behavior is superseded by 10_jcoins_automatic_refunds_and_delay_compensation.sql. Run migration 10 after the JCoins foundation (09) to enable automatic JCoins credits.

IMPORTANT: The SQL migration assumes the existing booking_cancellation_requests table has the columns used by the current cancel_booking function. Test on a staging/backup database first. The supplied project ZIP does not include a live database dump, so schema-dependent behavior cannot be fully verified offline.


COMBINED ONE-TIME BOOKING MODIFICATIONS (08_combined_booking_modifications.sql)
1. Back up the Supabase database and test on a staging project first.
2. Run 08_combined_booking_modifications.sql AFTER 05_cancellation_policy_fix.sql and after the existing change_booking_travel_date, upgrade_booking_class, and add_passenger_to_booking RPCs are present.
3. The migration adds bookings.modification_used, booking_change_requests, booking_change_payment_submissions, RLS policies, and RPCs for creating a combined request, submitting one receipt, cancelling an unpaid request, and reviewing the request.
4. The browser stages selected changes only. The original booking is not changed until an Admin approves the single combined request.
5. The 10-minute timer starts when the customer proceeds to the combined checkout. If all three change categories (date, class, passenger) are selected, the page proceeds directly to checkout. A user can cancel before submitting a receipt.
6. One combined request may include a date change, one class upgrade, and one additional passenger. Approval permanently sets bookings.modification_used=true. A second modification is blocked by the database. Further changes require cancellation of the whole original booking under the existing cancellation rules.
7. The modification fee is non-refundable. Cancelling the original booking does not refund the approved modification fee.
8. Admins and Super Admins review the combined receipt at booking-change-review.html. Approval applies all changes in one database transaction; rejection applies none. If rejected before the deadline, the user may upload a corrected receipt before the same deadline.
9. The customer can view requests at booking-changes.html. Modification receipts use the existing private payment-receipts Storage bucket.
10. IMPORTANT: the current front-end calculates an estimated additional amount (date fee ₱10, First Class upgrade ₱61, and estimated additional passenger fare based on current average fare per passenger). Admin must verify the exact amount against the fare/receipt before approval. The supplied ZIP does not contain the database function definitions or live schema dump, so the SQL function signatures and fare calculation must be validated in Supabase staging before production.
11. The QR/bank details remain placeholders. Receipt upload is not proof of actual payment and this workflow does not process bank transfers or issue refunds.


JJCC RAILWAYS - JCOINS REFUND & DELAY COMPENSATION UPDATE

New migration: 10_jcoins_automatic_refunds_and_delay_compensation.sql
Run it AFTER 09_jcoins_wallet_foundation.sql in Supabase SQL Editor. Back up your database first.

Policy implemented by this update:
- Voluntary cancellation within 24 hours after paid_at: booking is cancelled immediately and 50% of original fare is credited to JCoins. No admin approval.
- Railway-initiated cancellation: 100% of original fare is credited to JCoins. This is performed through the staff-only cancel_booking_by_railway RPC.
- Delay compensation is based on verified actual arrival versus scheduled arrival at the destination: under 30 minutes = 0%; 30-59 = 25%; 60-119 = 50%; 120+ = 100%. Eligible credits are issued automatically to JCoins.
- Delay data must be verified and recorded by authorized railway staff in delay-operations.html using record_train_delay_incident; passengers do not submit claims and do not need individual admin approval. This requires actual arrival data to be entered by an operational system or authorized staff.
- Payment receipt deadline remains 10 minutes. If no timely receipt is submitted, the booking expires and the seat is released. A timely receipt remains pending review.
- Flexible/Saver booking-change distinctions remain unchanged.

Important deployment notes:
1. Run migration 09 first if the JCoins wallet foundation has not already been installed.
2. Run migration 10 once, after migration 09. Do not run the SQL fragments individually.
3. Test first in a Supabase staging project with test accounts and bookings.
4. This update changes database RPC behavior and Travel Info text; it does not verify actual bank transfers or connect a payment processor. Receipt approval remains manual.
5. Automatic delay credits require a trusted source for actual arrival timestamps. The SQL exposes a staff-only RPC for recording verified arrivals; it does not infer real train arrival data from the demo live-status display.

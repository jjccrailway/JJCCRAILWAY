JJCC Railways – Admin & Super Admin Enhancement Patch

This is a PATCH for the project ZIP you supplied. Copy these files into the same folder as the existing JJCC Railways HTML/JS/CSS files and replace files with matching names.

Dashboard and navigation updates:
- Admin and Super Admin dashboards now have live metric cards for net revenue, bookings, train fleet, and pending reviews.
- Added a 7-day net-revenue bar overview, booking-status breakdown, and recent JCoins transaction table.
- Added quick links from dashboard cards to the relevant management pages.
- Removed the standalone Staff Notifications page/link. Pending approval notifications are shown through a bell beside Sign Out in the staff sidebar.
- The bell reads pending records directly from the shared review tables. When one staff member approves/resolves an item, it no longer appears for the other staff because it is no longer pending.
- Passenger Payment Review remains separate from Payment Approvals because the project has separate legacy booking-level and passenger-level receipt workflows.
- Super Admin keeps User Management and Admin Management; Admin does not receive those privileged links.

Other files carried forward from the earlier enhancement patch:
- Persistent staff sidebar on staff workflow pages.
- Fare management, finance ledger, payment/ID/booking-change/delay review pages.
- Broken-train cancellation migration.

Important financial definition:
- Dashboard net revenue is calculated from confirmed bookings with paid_at, less JCoins REFUND_CREDIT entries. It is a database-recorded operational figure, not a bank settlement or payment-gateway reconciliation report. JCoins-only payments and split-payment accounting may require a separate accounting policy before treating this as audited company cash revenue.
- The recent transactions panel shows the latest JCoins wallet ledger entries; it is not a complete external bank-transfer ledger.

Setup:
1. Back up your current project folder.
2. Extract this ZIP.
3. Copy/replace the included files into your existing project folder (same level as admin.html and superadmin.html).
4. Keep your existing Supabase configuration and migrations. Do not upload private .env files or service-role keys to GitHub.
5. If you use the broken-train automatic cancellation feature, run 23_broken_train_automatic_cancellation.sql in Supabase SQL Editor after migration 10_jcoins_automatic_refunds_and_delay_compensation.sql. Test with a test booking first.

Validation performed:
- JavaScript syntax checks and internal-link checks were run on the included patch files.
- This environment is not connected to your live Supabase project, so actual database permissions, RPC behavior, storage access, and end-to-end approvals still need a test account and test booking.

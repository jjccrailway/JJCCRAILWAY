JJCC RAILWAYS — ADMIN / SUPER ADMIN REVISION 2

Files in this patch (copy all into the root of your existing JJCC_Railways_Updated project and replace matching files):
- admin.html
- superadmin.html
- payments.html
- passenger-payment-review.html
- admin-theme.css
- staff-shell.js
- staff-notifications.js
- staff-dashboard.js

CHANGES
1. Replaced the sidebar on every staff page with the same shared navigation, retaining Super Admin's dashboard sections (Overview, User Management, Admin Management, Train Operations).
2. Moved Sign Out to the upper-right beside a bell notification button.
3. Notifications now open in a centered modal. Passenger-level receipt alerts open Payment Approvals > Passenger-level receipts.
4. Merged booking-level and passenger-level receipt review into Payment Approvals tabs. The old Passenger Payment Review URL redirects to the passenger-level tab.
5. Receipt View, Approve, and Reject actions are aligned together. Passenger name, booking reference, route, destination, travel date, cash amount, and JCoins are displayed when available.
6. Revenue chart labels now include weekday and calendar date.
7. Added null guards to Admin / Super Admin status-message handling to prevent the reported textContent-on-null error.

INSTALL
1. Back up your current project folder.
2. Extract this ZIP.
3. Copy the eight files into the root of JJCC_Railways_Updated, replacing the matching files.
4. Hard refresh the local site (Ctrl+Shift+R).

No SQL migration is included or required for these UI revisions. Existing database RPCs and table permissions still determine whether approval actions can complete. Test with an Admin and Super Admin account in your local environment.

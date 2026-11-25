JJCC RAILWAYS — PAYMENT / SEAT UI FIX

Files included:
- payment.html
- script.js
- start_payment_window.sql

IMPORTANT — APPLY IN THIS ORDER
1. Open Supabase SQL Editor.
2. Run start_payment_window.sql once. This adds a one-time payment-start timestamp and a secure RPC.
3. Replace payment.html and script.js in your JJCC_Railways_Updated project.
4. Keep your existing shared style.css unchanged. The visual updates are scoped to payment.html so other pages are not restyled.
5. Hard refresh the browser (Ctrl + Shift + R).

Changes:
- Occupied seats remain visible as dark navy seats and cannot be selected.
- The 10-minute countdown starts when Proceed to Payment is clicked.
- Refreshing the payment page reuses the same server-side deadline; it does not restart the timer.
- JCoins + Cash amount input and quick-action buttons use a styled branded component.
- Payment page spacing, cards, payment options, receipt upload, and countdown styling are improved without changing shared styles.

The SQL migration is required for the one-time server-side countdown behavior. Do not skip it.

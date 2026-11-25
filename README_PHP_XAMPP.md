# JJCC Railways: HTML pages + PHP server folder (Supabase is the database)

Your pages stay `.html`. PHP lives in the separate `php/` folder.

| Part | Purpose |
|---|---|
| `php/cron/expire.php` | Releases seats of unpaid bookings / modification requests / passenger holds (replaces pg_cron) |
| `php/api/health.php` | Supabase connection test |
| `php/api/admin-summary.php` | Admin-only example endpoint (checks login + role) |
| `php/src/*` | Supabase helper + role check |
| `php-api.js` | Adds `callPhp('endpoint.php')` to the pages (one line added after script.js in each page) |
| `php-check.php` | Setup check page |

## Setup
1. Install XAMPP, start **Apache**.
2. Copy `JJCC_Railways_Updated` to `C:\xampp\htdocs\`.
3. In `php\` copy `.env.example` to `.env`; paste your Supabase **secret** key and set `CRON_SECRET` (Notepad: Save As > All files).
4. Open `http://localhost/JJCC_Railways_Updated/php-check.php` - rows green, press the test button.
5. Open the site: `http://localhost/JJCC_Railways_Updated/`
6. Supabase > Authentication > URL Configuration: add `http://localhost/JJCC_Railways_Updated/**` to Redirect URLs (only needed if you run the site from XAMPP instead of Live Server).

## Seat-expiry job (every minute)
`C:\xampp\php\php.exe C:\xampp\htdocs\JJCC_Railways_Updated\php\cron\expire.php`
Schedule with Windows Task Scheduler, repeat every 1 minute.

## Use from a page (browser console, signed in as admin)
`callPhp('admin-summary.php').then(console.log).catch(console.error)`

<?php
declare(strict_types=1);
/**
 * Releases seats for unpaid bookings, unpaid modification requests and expired
 * passenger payment holds. Replaces pg_cron (migrations 02 and 17).
 *
 *   Command line (recommended):  php cron/expire.php
 *   By URL (needs the secret):   /cron/expire.php?key=YOUR_CRON_SECRET
 * Schedule it every minute (see README).
 */
require_once __DIR__ . '/../src/Supabase.php';

if (PHP_SAPI !== 'cli') {
    $given  = (string) ($_GET['key'] ?? ($_SERVER['HTTP_X_CRON_KEY'] ?? ''));
    $secret = env('CRON_SECRET');
    if ($secret === '' || !hash_equals($secret, $given)) {
        json_out(403, ['error' => 'Forbidden']);
    }
}

$jobs = ['expire_pending_bookings', 'expire_booking_change_requests', 'expire_passenger_payment_holds'];
$results = [];

try {
    $sb = Supabase::service();
} catch (Throwable $e) {
    log_line('config error: ' . $e->getMessage());
    if (PHP_SAPI === 'cli') { fwrite(STDERR, $e->getMessage() . PHP_EOL); exit(1); }
    json_out(500, ['error' => 'Server not configured']);
}

foreach ($jobs as $fn) {
    try {
        $r = $sb->rpc($fn);
        $ok = $r['status'] >= 200 && $r['status'] < 300;
        $results[$fn] = ['ok' => $ok, 'result' => $r['body']];
        if (!$ok) log_line("$fn failed: " . json_encode($r['body']));
    } catch (Throwable $e) {
        $results[$fn] = ['ok' => false, 'error' => $e->getMessage()];
        log_line("$fn exception: " . $e->getMessage());
    }
}

if (PHP_SAPI === 'cli') {
    foreach ($results as $fn => $r) echo $fn . ': ' . json_encode($r) . PHP_EOL;
    exit;
}
json_out(200, ['ran_at' => date('c'), 'jobs' => $results]);

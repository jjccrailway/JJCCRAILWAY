<?php
declare(strict_types=1);
require_once __DIR__ . '/../src/auth.php';
send_cors();

// Example protected endpoint: only admin / super_admin may call it.
$me = require_role(['admin', 'super_admin']);
$sb = Supabase::service();

// Counts rows in PHP (fine for small tables).
$count = function (string $table, string $filter) use ($sb): ?int {
    $r = $sb->select($table, 'select=*' . $filter);
    return ($r['status'] === 200 && is_array($r['body'])) ? count($r['body']) : null;
};

json_out(200, [
    'requested_by'     => $me,
    'pending_payments' => $count('bookings', '&booking_status=eq.pending_payment'),
    'confirmed'        => $count('bookings', '&booking_status=eq.confirmed'),
    'trains_broken'    => $count('trains', '&train_status=eq.broken'),
]);

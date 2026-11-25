<?php
declare(strict_types=1);
require_once __DIR__ . '/../src/Supabase.php';
send_cors();

// Connection test: reads 3 stations with the secret key.
try {
    $r = Supabase::service()->select('stations', 'select=*&limit=3');
    json_out($r['status'] === 200 ? 200 : 502, [
        'php'             => PHP_VERSION,
        'supabase_status' => $r['status'],
        'sample'          => $r['body'],
    ]);
} catch (Throwable $e) {
    json_out(500, ['error' => $e->getMessage()]);
}

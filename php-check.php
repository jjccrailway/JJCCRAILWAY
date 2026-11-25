<?php
// Setup check page: open http://localhost/JJCC_Railways_Updated/php-check.php
require_once __DIR__ . '/php/src/config.php';

$checks = [
  'PHP version (8.0+ needed)'   => [version_compare(PHP_VERSION, '8.0.0', '>='), PHP_VERSION],
  'cURL extension enabled'      => [extension_loaded('curl'), extension_loaded('curl') ? 'yes' : 'no'],
  'php/.env file found'         => [is_file(__DIR__ . '/php/.env'), is_file(__DIR__ . '/php/.env') ? 'yes' : 'missing - copy php/.env.example to php/.env'],
  'Supabase URL set'            => [env('SUPABASE_URL') !== '', env('SUPABASE_URL') !== '' ? env('SUPABASE_URL') : 'empty'],
  'Secret key set'              => [env('SUPABASE_SERVICE_KEY') !== '' && !str_contains(env('SUPABASE_SERVICE_KEY'), 'PASTE'), (env('SUPABASE_SERVICE_KEY') !== '' && !str_contains(env('SUPABASE_SERVICE_KEY'), 'PASTE')) ? 'yes (hidden)' : 'not set yet'],
];
?>
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>PHP Setup Check | JJCC Railways</title>
  <style>
    body{font-family:Inter,system-ui,sans-serif;background:#f4f6fb;margin:0;padding:40px 16px;color:#102044}
    .card{max-width:720px;margin:auto;background:#fff;border-radius:14px;padding:28px;box-shadow:0 6px 24px rgba(16,32,68,.1)}
    table{width:100%;border-collapse:collapse;margin:16px 0}
    td{padding:10px 8px;border-bottom:1px solid #e5e9f2}
    .ok{color:#14803c;font-weight:700}.bad{color:#b42318;font-weight:700}
    button{background:#102044;color:#fff;border:0;border-radius:8px;padding:10px 16px;cursor:pointer}
    pre{background:#f4f6fb;padding:12px;border-radius:8px;overflow:auto;font-size:13px}
  </style>
</head>
<body>
  <div class="card">
    <h1>PHP setup check</h1>
    <p>Server time (rendered by PHP): <strong><?= htmlspecialchars(date('Y-m-d H:i:s')) ?></strong></p>
    <table>
      <?php foreach ($checks as $label => [$ok, $detail]): ?>
        <tr>
          <td><?= htmlspecialchars($label) ?></td>
          <td class="<?= $ok ? 'ok' : 'bad' ?>"><?= $ok ? '✔' : '✘' ?> <?= htmlspecialchars((string) $detail) ?></td>
        </tr>
      <?php endforeach; ?>
    </table>
    <button id="testBtn" type="button">Test Supabase connection through PHP</button>
    <pre id="out">Click the button above.</pre>
  </div>
  <script>
    document.getElementById('testBtn').addEventListener('click', async () => {
      const out = document.getElementById('out');
      out.textContent = 'Testing...';
      try {
        const res = await fetch('php/api/health.php');
        out.textContent = JSON.stringify(await res.json(), null, 2);
      } catch (e) { out.textContent = 'Error: ' + e.message; }
    });
  </script>
</body>
</html>

<?php
declare(strict_types=1);
require_once __DIR__ . '/Supabase.php';

function bearer_token(): ?string
{
    $h = $_SERVER['HTTP_AUTHORIZATION'] ?? $_SERVER['REDIRECT_HTTP_AUTHORIZATION'] ?? '';
    if ($h === '' && function_exists('apache_request_headers')) {
        $all = array_change_key_case(apache_request_headers(), CASE_LOWER);
        $h = $all['authorization'] ?? '';
    }
    return preg_match('/^Bearer\s+(.+)$/i', $h, $m) ? trim($m[1]) : null;
}

/**
 * Require a logged-in user whose profiles.role is one of $roles.
 * The role is read from the database, never trusted from the browser.
 */
function require_role(array $roles): array
{
    $token = bearer_token();
    if (!$token) json_out(401, ['error' => 'Missing Authorization header']);

    $sb = Supabase::service();
    $user = $sb->verifyUser($token);
    if (!$user) json_out(401, ['error' => 'Invalid or expired session']);

    $res = $sb->select('profiles', 'select=role&id=eq.' . rawurlencode($user['id']) . '&limit=1');
    $role = is_array($res['body']) ? ($res['body'][0]['role'] ?? null) : null;
    if (!$role || !in_array($role, $roles, true)) json_out(403, ['error' => 'Not allowed']);

    return ['id' => $user['id'], 'email' => $user['email'] ?? null, 'role' => $role];
}

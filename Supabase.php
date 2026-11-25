<?php
declare(strict_types=1);
require_once __DIR__ . '/config.php';

/**
 * Tiny Supabase REST client (cURL).
 *  - Supabase::service()  -> uses the SECRET key (bypasses RLS). Server-side only.
 *  - verifyUser($jwt)     -> asks Supabase Auth whether a browser token is valid.
 */
final class Supabase
{
    private string $url;

    public function __construct(private string $key)
    {
        $this->url = rtrim(env('SUPABASE_URL'), '/');
        if ($this->url === '' || $this->key === '') {
            throw new RuntimeException('Supabase URL/key missing. Check your .env file.');
        }
    }

    public static function service(): self
    {
        return new self(env('SUPABASE_SERVICE_KEY'));
    }

    /** @return array{status:int, body:mixed} */
    public function request(string $method, string $path, mixed $json = null, ?string $bearer = null): array
    {
        $ch = curl_init($this->url . $path);
        curl_setopt_array($ch, [
            CURLOPT_CUSTOMREQUEST  => $method,
            CURLOPT_RETURNTRANSFER => true,
            CURLOPT_TIMEOUT        => 20,
            CURLOPT_HTTPHEADER     => [
                'apikey: ' . $this->key,
                'Authorization: Bearer ' . ($bearer ?? $this->key),
                'Content-Type: application/json',
                'Accept: application/json',
            ],
        ]);
        if ($json !== null) {
            curl_setopt($ch, CURLOPT_POSTFIELDS, json_encode($json));
        }
        $raw = curl_exec($ch);
        if ($raw === false) {
            $err = curl_error($ch);
            curl_close($ch);
            throw new RuntimeException('cURL error: ' . $err);
        }
        $status = (int) curl_getinfo($ch, CURLINFO_RESPONSE_CODE);
        curl_close($ch);

        $decoded = json_decode($raw, true);
        return ['status' => $status, 'body' => json_last_error() === JSON_ERROR_NONE ? $decoded : $raw];
    }

    /** Call a Postgres function: POST /rest/v1/rpc/<name> */
    public function rpc(string $fn, array $args = []): array
    {
        return $this->request('POST', '/rest/v1/rpc/' . rawurlencode($fn), $args === [] ? new stdClass() : $args);
    }

    /** SELECT helper. Example: select('profiles', 'select=role&id=eq.abc&limit=1') */
    public function select(string $table, string $query = ''): array
    {
        return $this->request('GET', '/rest/v1/' . rawurlencode($table) . ($query !== '' ? '?' . $query : ''));
    }

    /** Validate a browser access token. Returns the user array or null. */
    public function verifyUser(string $accessToken): ?array
    {
        $anon = new self(env('SUPABASE_ANON_KEY'));
        $res = $anon->request('GET', '/auth/v1/user', null, $accessToken);
        return ($res['status'] === 200 && is_array($res['body']) && isset($res['body']['id'])) ? $res['body'] : null;
    }
}

/* Calls the PHP server layer (php/api/*) with the signed-in user's Supabase token. */
(function () {
  const SUPABASE_URL = 'https://ocjyyfzuoiprwajwyize.supabase.co';
  const SUPABASE_KEY = 'sb_publishable_XZu8suOKCWB9Zp7dYhzxgQ_Yaq5zxo8';
  const PHP_API = 'php/api'; // same site, so no CORS setup is needed

  window.callPhp = async function (endpoint, options = {}) {
    if (!window.supabase) throw new Error('Supabase library not loaded');
    const client = window.supabase.createClient(SUPABASE_URL, SUPABASE_KEY);
    const { data: { session } } = await client.auth.getSession();
    const res = await fetch(`${PHP_API}/${endpoint}`, {
      ...options,
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${session?.access_token ?? ''}`,
        ...(options.headers || {})
      }
    });
    const body = await res.json().catch(() => ({}));
    if (!res.ok) throw new Error(body.error || `Server error (${res.status})`);
    return body;
  };
})();

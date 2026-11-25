(() => {
  'use strict';
  const URL = 'https://ocjyyfzuoiprwajwyize.supabase.co';
  const KEY = 'sb_publishable_XZu8suOKCWB9Zp7dYhzxgQ_Yaq5zxo8';
  if (!window.supabase || document.querySelector('.staff-notification-wrap')) return;
  const db = window.supabase.createClient(URL, KEY);
  const actions = document.querySelector('.staff-top-actions');
  if (!actions) return;
  const wrap = document.createElement('div');
  wrap.className = 'staff-notification-wrap';
  wrap.innerHTML = `<button class="staff-notification-button" type="button" aria-label="Open notifications" aria-expanded="false"><span aria-hidden="true">🔔</span><b class="staff-notification-count" hidden>0</b></button>`;
  const overlay = document.createElement('div');
  overlay.className = 'staff-notification-overlay';
  overlay.hidden = true;
  overlay.innerHTML = `<section class="staff-notification-panel" role="dialog" aria-modal="true" aria-label="Staff notifications"><div class="staff-notification-heading"><strong>Notifications</strong><span class="staff-notification-subtitle">Pending items that need staff attention</span></div><div class="staff-notification-list"><p class="staff-notification-empty">Loading pending items…</p></div><div class="staff-notification-footer">A request disappears after it has been approved or resolved by any staff member.</div></section>`;
  actions.prepend(wrap);
  document.body.appendChild(overlay);
  const button = wrap.querySelector('button');
  const badge = wrap.querySelector('.staff-notification-count');
  const list = overlay.querySelector('.staff-notification-list');
  const esc = s => String(s ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  const sources = [
    { table:'payment_submissions', statusColumn:'status', pending:'pending_review', date:'submitted_at', title:'Payment receipt uploaded', page:'payments.html', label:'Booking payment' },
    { table:'passenger_payment_submissions', statusColumn:'status', pending:'pending_review', date:'submitted_at', title:'Passenger receipt uploaded', page:'payments.html#passenger-level', label:'Passenger payment' },
    { table:'discount_id_submissions', statusColumn:'status', pending:'pending_review', date:'submitted_at', title:'Discount ID submitted', page:'discount-review.html', label:'ID verification' },
    { table:'booking_change_payment_submissions', statusColumn:'status', pending:'pending_review', date:'submitted_at', title:'Booking change receipt uploaded', page:'booking-change-review.html', label:'Booking change' },
    { table:'delay_compensation_requests', statusColumn:'request_status', pending:'pending', date:'requested_at', title:'Delay compensation requested', page:'delay-requests.html', label:'Delay compensation' }
  ];
  async function loadPending() {
    const results = await Promise.all(sources.map(async source => {
      const { data, error } = await db.from(source.table).select('*').eq(source.statusColumn, source.pending).order(source.date, { ascending:false }).limit(30);
      if (error) throw new Error(`${source.label}: ${error.message}`);
      return (data || []).map(row => ({ source, row }));
    }));
    const items = results.flat().sort((a,b) => new Date(b.row[a.source.date]) - new Date(a.row[b.source.date]));
    badge.textContent = String(items.length);
    badge.hidden = items.length === 0;
    list.innerHTML = items.length ? items.slice(0,30).map(({source,row}) => {
      const reference = row.booking_reference || (row.booking_id ? `Booking #${row.booking_id}` : `Request #${row.submission_id || row.request_id || '—'}`);
      const dateValue = row[source.date] ? new Date(row[source.date]).toLocaleString('en-PH') : '';
      return `<a class="staff-notification-item" href="${source.page}"><span class="staff-notification-dot"></span><span><strong>${esc(source.title)}</strong><small>${esc(reference)} · ${esc(source.label)}</small><time>${esc(dateValue)}</time></span><span aria-hidden="true">›</span></a>`;
    }).join('') : '<p class="staff-notification-empty">You are all caught up. No pending approvals.</p>';
  }
  function close(){ overlay.hidden = true; button.setAttribute('aria-expanded','false'); }
  button.addEventListener('click', async () => {
    const opening = overlay.hidden;
    overlay.hidden = !opening;
    button.setAttribute('aria-expanded', String(opening));
    if (opening) {
      list.innerHTML = '<p class="staff-notification-empty">Refreshing pending items…</p>';
      try { await loadPending(); }
      catch (error) { list.innerHTML = `<p class="staff-notification-error">${esc(error.message)}<br>Check that the required database migrations are installed.</p>`; }
    }
  });
  overlay.addEventListener('click', event => { if (event.target === overlay) close(); });
  document.addEventListener('keydown', event => { if (event.key === 'Escape') close(); });
  loadPending().catch(error => console.warn('Staff notifications:', error.message));
  window.setInterval(() => loadPending().catch(error => console.warn('Staff notifications:', error.message)), 60000);
})();

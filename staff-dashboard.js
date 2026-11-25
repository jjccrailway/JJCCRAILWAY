(() => {
  'use strict';
  const URL = 'https://ocjyyfzuoiprwajwyize.supabase.co';
  const KEY = 'sb_publishable_XZu8suOKCWB9Zp7dYhzxgQ_Yaq5zxo8';
  const db = window.supabase.createClient(URL, KEY);
  const $ = (id) => document.getElementById(id);
  const money = (n) => new Intl.NumberFormat('en-PH', { style: 'currency', currency: 'PHP', maximumFractionDigits: 2 }).format(Number(n || 0));
  const set = (id, value) => { const el = $(id); if (el) el.textContent = value; };
  const safe = (value) => String(value ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  const statusOf = (b) => String(b.booking_status || b.status || '').toLowerCase().replaceAll(' ', '_');
  const isConfirmed = (b) => statusOf(b) === 'confirmed';

  async function countPending(table, column, value) {
    const { count, error } = await db.from(table).select('*', { count: 'exact', head: true }).eq(column, value);
    if (error) throw error;
    return Number(count || 0);
  }

  function renderRevenueBars(daily) {
    const host = $('revenueBars');
    if (!host) return;
    const rows = Array.isArray(daily) ? daily : [];
    if (!rows.length) { host.innerHTML = '<p class="panel-caption">No payment activity recorded for this period.</p>'; return; }
    const max = Math.max(1, ...rows.map(x => Number(x.net || 0)));
    host.innerHTML = rows.map(x => {
      const date = new Date(`${x.date}T12:00:00+08:00`);
      const label = date.toLocaleDateString('en-PH',{weekday:'short'}) + ' · ' +
        date.toLocaleDateString('en-PH',{month:'short',day:'numeric'});
      return `<div class="revenue-day" title="${safe(label)} · Gross ${money(x.gross)} · Refunds ${money(x.refunds)}">
        <div class="revenue-bar-track"><div class="revenue-bar" style="height:${Math.max(3, Number(x.net || 0) / max * 100)}%"></div></div>
        <span>${safe(label)}</span><small>${money(x.net)}</small></div>`;
    }).join('');
  }

  function renderTransactions(rows) {
    const host = $('recentTransactions');
    if (!host) return;
    if (!rows.length) { host.innerHTML = '<tr><td colspan="5">No JCoins transactions recorded yet.</td></tr>'; return; }
    host.innerHTML = rows.slice(0, 6).map(tx => `<tr><td>${safe(new Date(tx.created_at).toLocaleString('en-PH'))}</td><td>${safe(tx.booking_reference || '—')}</td><td>${safe(String(tx.transaction_type || '').replaceAll('_',' '))}</td><td>${safe(tx.direction || '—')}</td><td>${money(tx.amount)}</td></tr>`).join('');
  }

  function renderBookingStatus(bookings) {
    const host = $('bookingStatusBreakdown');
    if (!host) return;
    const groups = [
      ['Confirmed', bookings.filter(isConfirmed).length, 'confirmed'],
      ['Pending / To Pay', bookings.filter(b => ['pending','pending_payment','to_pay','awaiting_payment'].includes(statusOf(b))).length, 'pending'],
      ['Cancelled / Expired', bookings.filter(b => ['cancelled','expired'].includes(statusOf(b))).length, 'cancelled']
    ];
    const total = Math.max(1, bookings.length);
    host.innerHTML = groups.map(([label,count,kind]) => `<div class="status-metric"><div><span>${label}</span><strong>${count}</strong></div><div class="status-track"><i class="${kind}" style="width:${count/total*100}%"></i></div></div>`).join('');
  }

  async function load() {
    const message = $('dashboardDataStatus');
    try {
      const [{ data: bookingRows, error: bookingError }, { data: trains, error: trainError }, { data: finance, error: financeError }] = await Promise.all([
        db.rpc('get_staff_booking_records'),
        db.from('trains').select('train_id,train_code,train_name,train_status').not('train_code','like','RTG-%'),
        db.rpc('get_staff_financial_summary', { p_days: 7 })
      ]);
      if (bookingError) throw bookingError;
      if (trainError) throw trainError;
      if (financeError) throw financeError;
      const bookings = (bookingRows || []).map(x => x.booking || x);
      const trainRows = trains || [];
      const gross = Number(finance?.gross || 0);
      const refundTotal = Number(finance?.refunds || 0);
      const net = Number(finance?.net ?? gross - refundTotal);
      const tx = finance?.recent_transactions || [];
      set('dashboardRevenue', money(net));
      set('dashboardGrossRevenue', money(gross));
      set('dashboardRefunds', money(refundTotal));
      set('dashboardBookings', bookings.length);
      set('dashboardConfirmed', bookings.filter(isConfirmed).length);
      set('dashboardCancelled', bookings.filter(b => ['cancelled','expired'].includes(statusOf(b))).length);
      set('dashboardTrains', trainRows.length);
      set('dashboardActiveTrains', trainRows.filter(t => t.train_status === 'active').length);
      set('dashboardBrokenTrains', trainRows.filter(t => t.train_status === 'broken').length);
      set('dashboardMaintenanceTrains', trainRows.filter(t => t.train_status === 'under_maintenance').length);
      set('dashboardOutTrains', trainRows.filter(t => t.train_status === 'out_of_service').length);
      renderRevenueBars(finance?.daily || []);
      renderTransactions(tx);
      renderBookingStatus(bookings);

      const pendingChecks = await Promise.all([
        countPending('payment_submissions','status','pending_review'),
        countPending('passenger_payment_submissions','status','pending_review'),
        countPending('discount_id_submissions','status','pending_review'),
        countPending('booking_change_payment_submissions','status','pending_review'),
        countPending('delay_compensation_requests','request_status','pending')
      ]);
      const pending = pendingChecks.reduce((a,b) => a+b,0);
      set('dashboardPending', pending);
      set('dashboardDataStatus', `Updated ${new Date().toLocaleTimeString('en-PH')} · Figures reflect records currently available in Supabase.`);
      if (message) message.classList.remove('error');
    } catch (error) {
      console.error('Staff dashboard data error:', error);
      if (message) { message.textContent = `Some dashboard data could not be loaded: ${error.message || 'Check database access and migrations.'}`; message.classList.add('error'); }
    }
  }

  load();
  const refresh = $('refreshDashboard');
  if (refresh) refresh.addEventListener('click', () => { refresh.disabled = true; load().finally(() => { refresh.disabled = false; }); });
  window.addEventListener('focus', load);
})();

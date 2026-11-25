(() => {
  'use strict';

  const SUPABASE_URL = 'https://ocjyyfzuoiprwajwyize.supabase.co';
  const SUPABASE_KEY = 'sb_publishable_XZu8suOKCWB9Zp7dYhzxgQ_Yaq5zxo8';
  const client = window.supabase.createClient(SUPABASE_URL, SUPABASE_KEY);

  const $ = (selector) => document.querySelector(selector);
  const formatCoins = (value) => `${Number(value || 0).toLocaleString('en-PH', {
    minimumFractionDigits: 2,
    maximumFractionDigits: 2
  })} JCoins`;
  const formatDate = (value) => value
    ? new Intl.DateTimeFormat('en-PH', {
        dateStyle: 'medium',
        timeStyle: 'short',
        hourCycle: 'h23'
      }).format(new Date(value))
    : '—';

  const transactionLabel = (type) => ({
    REFUND_CREDIT: 'Booking refund',
    DELAY_COMPENSATION: 'Delay compensation',
    BOOKING_PAYMENT: 'Booking payment',
    BOOKING_PAYMENT_REVERSAL: 'Payment reversal',
    ADMIN_ADJUSTMENT: 'Account adjustment'
  }[type] || String(type || 'Wallet transaction').replaceAll('_', ' '));

  async function loadWallet() {
    const message = $('#jcoinsMessage');
    const button = $('#refreshJcoins');
    button.disabled = true;
    message.className = 'notice notice-info';
    message.textContent = 'Loading your wallet…';

    try {
      const { data: authData, error: authError } = await client.auth.getUser();
      if (authError) throw authError;
      const user = authData?.user;
      if (!user) {
        location.replace('signin.html');
        return;
      }

      const [{ data: wallet, error: walletError }, { data: transactions, error: txError }] = await Promise.all([
        client.from('jcoins_wallets')
          .select('balance,total_earned,total_spent')
          .eq('user_id', user.id)
          .maybeSingle(),
        client.from('jcoins_transactions')
          .select('transaction_id,transaction_type,direction,amount,balance_after,booking_reference,description,created_at')
          .eq('user_id', user.id)
          .order('created_at', { ascending: false })
          .limit(100)
      ]);

      if (walletError) throw walletError;
      if (txError) throw txError;
      if (!wallet) {
        throw new Error('Your JCoins wallet has not been initialized. Please contact JJCC Railways support.');
      }

      $('#jcoinsBalance').innerHTML = `${formatCoins(wallet.balance).replace(' JCoins','')} <small>JCoins</small>`;
      $('#jcoinsEarned').textContent = formatCoins(wallet.total_earned);
      $('#jcoinsSpent').textContent = formatCoins(wallet.total_spent);

      const rows = transactions || [];
      $('#jcoinsTransactions').innerHTML = rows.length
        ? rows.map((item) => {
            const isCredit = item.direction === 'credit';
            const sign = isCredit ? '+' : '−';
            const ref = item.booking_reference
              ? `<span class="jcoins-reference">${escapeHTML(item.booking_reference)}</span>`
              : '—';
            return `<tr>
              <td>${escapeHTML(formatDate(item.created_at))}</td>
              <td><strong>${escapeHTML(transactionLabel(item.transaction_type))}</strong>${item.description ? `<small>${escapeHTML(item.description)}</small>` : ''}</td>
              <td>${ref}</td>
              <td class="${isCredit ? 'jcoins-credit' : 'jcoins-debit'}">${sign}${formatCoins(item.amount)}</td>
              <td>${formatCoins(item.balance_after)}</td>
            </tr>`;
          }).join('')
        : '<tr><td colspan="5" class="jcoins-empty">No transactions yet. Your JCoins activity will appear here.</td></tr>';

      message.className = 'notice notice-ok';
      message.textContent = 'Your wallet is up to date.';
    } catch (error) {
      console.error('JCoins wallet load failed:', error);
      message.className = 'notice notice-err';
      message.textContent = error.message || 'Unable to load your JCoins wallet.';
      $('#jcoinsTransactions').innerHTML = '<tr><td colspan="5" class="jcoins-empty">Transactions could not be loaded.</td></tr>';
    } finally {
      button.disabled = false;
    }
  }

  function escapeHTML(value) {
    return String(value ?? '').replace(/[&<>"']/g, (char) => ({
      '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'
    }[char]));
  }

  document.addEventListener('DOMContentLoaded', () => {
    $('#refreshJcoins')?.addEventListener('click', loadWallet);
    loadWallet();
  });
})();

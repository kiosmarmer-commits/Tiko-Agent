(() => {
  const $ = (s) => document.querySelector(s);
  const msgs = $('#messages');
  const form = $('#chatForm');
  const input = $('#input');
  const sendBtn = $('#sendBtn');
  const statusPill = $('#statusPill');

  const store = {
    get base() { return localStorage.getItem('agent_base') || location.origin; },
    set base(v) { localStorage.setItem('agent_base', v); },
    get token() { return localStorage.getItem('agent_token') || ''; },
    set token(v) { localStorage.setItem('agent_token', v); },
  };

  $('#cfgBase').value = store.base;
  $('#cfgToken').value = store.token;
  $('#saveCfg').onclick = () => {
    store.base = $('#cfgBase').value.trim().replace(/\/$/, '');
    store.token = $('#cfgToken').value.trim();
    addMsg('system', 'Setelan disimpan.');
    ping();
  };

  document.querySelectorAll('.tabs button').forEach((btn) => {
    btn.onclick = () => {
      document.querySelectorAll('.tabs button').forEach((b) => b.classList.remove('active'));
      document.querySelectorAll('.tab').forEach((t) => t.classList.remove('active'));
      btn.classList.add('active');
      $('#tab-' + btn.dataset.tab).classList.add('active');
      if (btn.dataset.tab === 'status') loadStatus();
      if (btn.dataset.tab === 'memory') loadMemory();
      if (btn.dataset.tab === 'approvals') loadApprovals();
      if (btn.dataset.tab === 'sessions') loadSessions();
    };
  });

  function addMsg(role, text) {
    const el = document.createElement('div');
    el.className = 'msg ' + role;
    el.textContent = text;
    msgs.appendChild(el);
    msgs.scrollTop = msgs.scrollHeight;
    return el;
  }

  async function api(path, opts = {}) {
    const res = await fetch(store.base + path, {
      ...opts,
      headers: {
        'Authorization': 'Bearer ' + store.token,
        'Content-Type': 'application/json',
        ...(opts.headers || {}),
      },
    });
    if (!res.ok) throw new Error(await res.text());
    return res.json();
  }

  async function ping() {
    try {
      const s = await api('/v1/status');
      statusPill.textContent = s.provider ? 'online · ' + s.provider : 'online';
      statusPill.className = 'pill online';
      return s;
    } catch (e) {
      statusPill.textContent = 'offline';
      statusPill.className = 'pill offline';
      return null;
    }
  }

  async function loadStatus() {
    try {
      const s = await api('/v1/status');
      $('#statusBox').textContent = JSON.stringify(s, null, 2);
    } catch (e) {
      $('#statusBox').textContent = String(e);
    }
  }

  async function loadMemory() {
    const ul = $('#memList');
    ul.innerHTML = '';
    try {
      const data = await api('/v1/memories');
      const list = data.memories || [];
      if (!list.length) {
        ul.innerHTML = '<li class="hint">Belum ada memori tersimpan.</li>';
        return;
      }
      list.forEach((m) => {
        const li = document.createElement('li');
        li.innerHTML = '<strong>' + (m.kind || 'fact') + '</strong> · ' +
          '<span class="hint">' + (m.importance ?? '') + '</span><br/>' +
          escapeHtml(m.text || JSON.stringify(m));
        ul.appendChild(li);
      });
    } catch (e) {
      ul.innerHTML = '<li>' + escapeHtml(String(e)) + '</li>';
    }
  }

  function escapeHtml(s) {
    return s.replace(/[&<>"']/g, (c) => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  }

  let busy = false;
  form.onsubmit = async (ev) => {
    ev.preventDefault();
    const text = input.value.trim();
    if (!text || busy) return;
    busy = true;
    sendBtn.disabled = true;
    input.value = '';
    addMsg('user', text);
    const thinking = addMsg('assistant', 'Menulis');
    thinking.classList.add('typing');
    try {
      // Prefer HTTP message (simple & reliable); WS optional
      const data = await api('/v1/messages', {
        method: 'POST',
        body: JSON.stringify({ text, session_key: 'web:default', user_key: 'web' }),
      });
      thinking.classList.remove('typing');
      thinking.textContent = data.text || '(kosong)';
    } catch (e) {
      thinking.classList.remove('typing');
      thinking.textContent = 'Gagal: ' + e.message;
    } finally {
      busy = false;
      sendBtn.disabled = false;
      input.focus();
    }
  };

  $('#refreshStatus').onclick = loadStatus;
  $('#refreshMem').onclick = loadMemory;

  // Welcome
  addMsg('system', 'Selamat datang. Tanyakan sesuatu — agent bisa hitung, baca file, dan merencanakan tugas.');
  ping();
  setInterval(ping, 15000);
})();

async function loadApprovals() {
  const r = await api('/v1/approvals');
  const ul = document.getElementById('approval-list');
  if (!ul) return;
  ul.innerHTML = '';
  for (const a of (r.approvals || [])) {
    const li = document.createElement('li');
    li.textContent = `${a.id} ${a.state} ${a.tool} ${a.risk}`;
    if (a.state === 'pending') {
      const b1 = document.createElement('button');
      b1.textContent = 'Approve';
      b1.onclick = async () => { await api('/v1/approvals/' + a.id, { method:'POST', body: JSON.stringify({approve:true}) }); loadApprovals(); };
      const b2 = document.createElement('button');
      b2.textContent = 'Deny';
      b2.onclick = async () => { await api('/v1/approvals/' + a.id, { method:'POST', body: JSON.stringify({approve:false}) }); loadApprovals(); };
      li.appendChild(b1); li.appendChild(b2);
    }
    ul.appendChild(li);
  }
}
async function loadSessions() {
  const r = await api('/v1/sessions');
  const ul = document.getElementById('session-list');
  if (!ul) return;
  ul.innerHTML = '';
  for (const s of (r.sessions || [])) {
    const li = document.createElement('li');
    li.textContent = `${s.id} ${s.channel || ''} ${s.updated_at || ''}`;
    ul.appendChild(li);
  }
}
document.getElementById('btn-refresh-approvals')?.addEventListener('click', loadApprovals);
document.getElementById('btn-refresh-sessions')?.addEventListener('click', loadSessions);

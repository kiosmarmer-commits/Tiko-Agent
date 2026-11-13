(() => {
  'use strict';

  const $ = (selector) => document.querySelector(selector);
  const msgs = $('#messages');
  const form = $('#chatForm');
  const input = $('#input');
  const sendBtn = $('#sendBtn');
  const statusPill = $('#statusPill');
  const confirmBox = $('#confirmBox');
  const confirmText = $('#confirmText');
  const confirmYes = $('#confirmYes');
  const confirmNo = $('#confirmNo');

  if (!msgs || !form || !input || !sendBtn || !statusPill) return;

  const store = {
    get base() { return localStorage.getItem('agent_base') || location.origin; },
    set base(value) { localStorage.setItem('agent_base', value); },
    get token() { return localStorage.getItem('agent_token') || ''; },
    set token(value) { localStorage.setItem('agent_token', value); },
  };

  const cfgBase = $('#cfgBase');
  const cfgToken = $('#cfgToken');
  if (cfgBase) cfgBase.value = store.base;
  if (cfgToken) cfgToken.value = store.token;

  let busy = false;
  let pingInFlight = false;
  let socket = null;
  let activeAssistant = null;
  let activeTurnFinished = false;
  let pendingConfirm = null;

  function setBusy(value) {
    busy = value;
    sendBtn.disabled = value;
    sendBtn.textContent = value ? 'Mengirim…' : 'Kirim';
    sendBtn.setAttribute('aria-busy', String(value));
  }

  function addMsg(role, text) {
    const el = document.createElement('div');
    el.className = 'msg ' + role;
    el.textContent = String(text ?? '');
    el.setAttribute('role', role === 'system' ? 'status' : 'article');
    msgs.appendChild(el);
    msgs.scrollTop = msgs.scrollHeight;
    return el;
  }

  function showConfirm(id, prompt) {
    if (!id || !confirmBox || !confirmText) return;
    pendingConfirm = { id, prompt };
    confirmText.textContent = prompt || 'Agent meminta izin menjalankan tool.';
    confirmBox.classList.remove('hidden');
    confirmYes.disabled = false;
    confirmNo.disabled = false;
  }

  function hideConfirm() {
    pendingConfirm = null;
    confirmBox?.classList.add('hidden');
    if (confirmYes) confirmYes.disabled = false;
    if (confirmNo) confirmNo.disabled = false;
  }

  async function api(path, options = {}) {
    const base = store.base.replace(/\/+$/, '');
    const headers = {
      Authorization: 'Bearer ' + store.token,
      ...(options.body ? { 'Content-Type': 'application/json' } : {}),
      ...(options.headers || {}),
    };
    const response = await fetch(base + path, { ...options, headers });
    if (!response.ok) {
      let detail = '';
      try { detail = await response.text(); } catch (_) { /* keep status fallback */ }
      throw new Error(detail || ('HTTP ' + response.status));
    }
    if (response.status === 204) return {};
    return response.json();
  }

  function setConnection(online, provider) {
    statusPill.textContent = online ? (provider ? 'online · ' + provider : 'online') : 'offline';
    statusPill.className = online ? 'pill online' : 'pill offline';
    statusPill.setAttribute('aria-label', online ? 'Daemon online' : 'Daemon offline');
  }

  async function ping() {
    if (pingInFlight) return;
    pingInFlight = true;
    try {
      const status = await api('/v1/status');
      setConnection(true, status.provider);
    } catch (_) {
      setConnection(false);
    } finally {
      pingInFlight = false;
    }
  }

  async function loadStatus() {
    const box = $('#statusBox');
    if (!box) return;
    box.textContent = 'Memuat status…';
    try {
      box.textContent = JSON.stringify(await api('/v1/status'), null, 2);
    } catch (error) {
      box.textContent = 'Gagal memuat status: ' + error.message;
    }
  }

  function emptyItem(message) {
    const li = document.createElement('li');
    li.className = 'empty-state';
    li.textContent = message;
    return li;
  }

  async function loadMemory() {
    const list = $('#memList');
    if (!list) return;
    list.replaceChildren(emptyItem('Memuat memori…'));
    try {
      const data = await api('/v1/memories');
      const memories = Array.isArray(data.memories) ? data.memories : [];
      list.replaceChildren();
      if (!memories.length) {
        list.appendChild(emptyItem('Belum ada memori tersimpan.'));
        return;
      }
      for (const memory of memories) {
        const li = document.createElement('li');
        const title = document.createElement('strong');
        title.textContent = String(memory.kind || 'fact');
        const meta = document.createElement('span');
        meta.className = 'hint';
        meta.textContent = ' · prioritas ' + String(memory.importance ?? '—');
        const body = document.createElement('p');
        body.textContent = String(memory.text ?? JSON.stringify(memory));
        li.append(title, meta, body);
        list.appendChild(li);
      }
    } catch (error) {
      list.replaceChildren(emptyItem('Gagal memuat memori: ' + error.message));
    }
  }

  async function loadSkills() {
    const list = $('#skill-list');
    if (!list) return;
    list.replaceChildren(emptyItem('Memuat skills…'));
    try {
      const data = await api('/v1/skills');
      const skills = Array.isArray(data.skills) ? data.skills : [];
      list.replaceChildren();
      if (!skills.length) {
        list.appendChild(emptyItem('Belum ada skill terdaftar.'));
        return;
      }
      for (const skill of skills) {
        const li = document.createElement('li');
        const title = document.createElement('strong');
        title.textContent = String(skill.slug || skill.name || '');
        const meta = document.createElement('span');
        meta.className = 'hint';
        const m = skill.metrics || {};
        meta.textContent = ' · ' + String(skill.status || 'draft') +
          ' · uses ' + String(m.uses ?? 0) +
          ' · 👍 ' + String(m.positive ?? 0) +
          ' · 👎 ' + String(m.negative ?? 0);
        const row = document.createElement('div');
        row.className = 'row';
        const up = document.createElement('button');
        up.type = 'button';
        up.className = 'secondary';
        up.textContent = '👍';
        up.setAttribute('aria-label', 'Feedback positif untuk ' + String(skill.slug || ''));
        up.addEventListener('click', () => sendSkillFeedback(skill.slug, true));
        const down = document.createElement('button');
        down.type = 'button';
        down.className = 'danger-button';
        down.textContent = '👎';
        down.setAttribute('aria-label', 'Feedback negatif untuk ' + String(skill.slug || ''));
        down.addEventListener('click', () => sendSkillFeedback(skill.slug, false));
        row.append(up, down);
        li.append(title, meta, row);
        list.appendChild(li);
      }
    } catch (error) {
      list.replaceChildren(emptyItem('Gagal memuat skills: ' + error.message));
    }
  }

  async function sendSkillFeedback(slug, positive) {
    try {
      await api('/v1/skills/' + encodeURIComponent(slug) + '/feedback', {
        method: 'POST',
        body: JSON.stringify({ positive }),
      });
      addMsg('system', 'Feedback ' + (positive ? '👍' : '👎') + ' untuk skill "' + slug + '" dicatat.');
      loadSkills();
    } catch (error) {
      addMsg('system', 'Gagal mengirim feedback: ' + error.message);
    }
  }

  const KANBAN_STATES = ['backlog', 'doing', 'done', 'failed'];
  let eventFeedItems = 0;

  async function loadTasks() {
    const board = $('#task-board');
    if (!board) return;
    board.replaceChildren();
    const loading = document.createElement('p');
    loading.className = 'hint';
    loading.textContent = 'Memuat tugas\u2026';
    board.appendChild(loading);
    try {
      const data = await api('/v1/tasks');
      const tasks = Array.isArray(data.tasks) ? data.tasks : [];
      board.replaceChildren();
      board.classList.remove('loading');
      for (const state of KANBAN_STATES) {
        const col = document.createElement('div');
        col.className = 'board-col board-col-' + state;
        const heading = document.createElement('h3');
        heading.textContent = state + ' (' + tasks.filter((t) => t.state === state).length + ')';
        col.appendChild(heading);
        const cards = tasks.filter((t) => t.state === state);
        if (!cards.length) {
          const empty = document.createElement('p');
          empty.className = 'hint';
          empty.textContent = '(kosong)';
          col.appendChild(empty);
        }
        for (const task of cards) {
          const card = document.createElement('div');
          card.className = 'task-card';
          const title = document.createElement('strong');
          title.textContent = String(task.title || '');
          const meta = document.createElement('p');
          meta.className = 'hint';
          meta.textContent = String(task.id || '') +
            (task.claimed_by ? ' \u00b7 by ' + String(task.claimed_by) : '') +
            (task.result ? ' \u00b7 ' + String(task.result) : '');
          card.append(title, meta);
          col.appendChild(card);
        }
        board.appendChild(col);
      }
    } catch (error) {
      board.classList.remove('loading');
      board.replaceChildren();
      const fail = document.createElement('p');
      fail.className = 'hint';
      fail.textContent = 'Gagal memuat tugas: ' + error.message;
      board.appendChild(fail);
    }
  }

  function appendEventFeed(detail) {
    const feed = $('#event-feed');
    if (!feed) return;
    const li = document.createElement('li');
    const title = document.createElement('strong');
    title.textContent = String(detail.type || 'event');
    const meta = document.createElement('span');
    meta.className = 'hint';
    meta.textContent = ' \u00b7 ' + String(detail.at || '') +
      (detail.tool ? ' \u00b7 ' + String(detail.tool) : '') +
      (detail.id ? ' \u00b7 ' + String(detail.id) : '');
    li.append(title, meta);
    feed.prepend(li);
    eventFeedItems += 1;
    while (feed.children.length > 50) feed.removeChild(feed.lastChild);
  }

  let watchSocket = null;
  let watchBackoffMs = 1000;

  function watchEvents() {
    if (!store.token || watchSocket) return;
    let ws;
    try {
      ws = new WebSocket(websocketUrl());
    } catch (_) {
      return;
    }
    watchSocket = ws;
    ws.addEventListener('message', (message) => {
      try {
        const payload = JSON.parse(message.data);
        if (payload.type === 'event' && payload.event) {
          appendEventFeed(payload.event);
          const type = String(payload.event.type || '');
          if (type.startsWith('job.') && !$('#tab-tasks').hidden) loadTasks();
        }
      } catch (_) { /* ignore malformed frames */ }
    });
    ws.addEventListener('close', () => {
      watchSocket = null;
      window.setTimeout(watchEvents, watchBackoffMs);
      watchBackoffMs = Math.min(watchBackoffMs * 2, 30000);
    });
    ws.addEventListener('open', () => { watchBackoffMs = 1000; });
  }

  async function loadLogs() {
    const select = $('#logSelect');
    if (!select) return;
    try {
      const data = await api('/v1/logs');
      const logs = Array.isArray(data.logs) ? data.logs : [];
      select.replaceChildren();
      if (!logs.length) {
        const option = document.createElement('option');
        option.textContent = '(belum ada log)';
        select.appendChild(option);
        return;
      }
      for (const log of logs) {
        const option = document.createElement('option');
        option.value = String(log.name || '');
        option.textContent = String(log.name || '') + ' (' + String(log.bytes ?? '?') + ' B)';
        select.appendChild(option);
      }
      await loadLogContent(String(logs[0].name || ''));
    } catch (error) {
      const view = $('#log-view');
      if (view) view.textContent = 'Gagal memuat daftar log: ' + error.message;
    }
  }

  async function loadLogContent(name) {
    const view = $('#log-view');
    if (!view || !name) return;
    view.textContent = 'Memuat ' + name + '\u2026';
    try {
      const data = await api('/v1/logs/' + encodeURIComponent(name));
      const header = (data.truncated ? '[dipotong, 64KB terakhir] ' : '') +
        String(data.name || name) + ' \u00b7 ' + String(data.bytes ?? '?') + ' B\n\n';
      view.textContent = header + String(data.content ?? '');
    } catch (error) {
      view.textContent = 'Gagal memuat log: ' + error.message;
    }
  }

  async function requestApproval(id, approve) {
    return api('/v1/approvals/' + encodeURIComponent(id), {
      method: 'POST',
      body: JSON.stringify({ approve }),
    });
  }

  async function decidePending(approve) {
    const request = pendingConfirm;
    if (!request) return;
    confirmYes.disabled = true;
    confirmNo.disabled = true;
    try {
      const result = await requestApproval(request.id, approve);
      if (!result.ok) throw new Error('Persetujuan tidak lagi pending atau sudah kedaluwarsa.');
      if (pendingConfirm?.id === request.id) hideConfirm();
      addMsg('system', (approve ? 'Izin diberikan untuk ' : 'Permintaan ditolak: ') + request.id + '.');
    } catch (error) {
      confirmYes.disabled = false;
      confirmNo.disabled = false;
      addMsg('system', 'Gagal mengirim keputusan: ' + error.message);
    }
  }

  async function decideListedApproval(id, approve, actions) {
    const buttons = actions.querySelectorAll('button');
    buttons.forEach((button) => { button.disabled = true; });
    try {
      const result = await requestApproval(id, approve);
      if (!result.ok) throw new Error('Approval sudah diproses atau kedaluwarsa.');
      await loadApprovals();
      addMsg('system', (approve ? 'Izin diberikan: ' : 'Permintaan ditolak: ') + id);
    } catch (error) {
      buttons.forEach((button) => { button.disabled = false; });
      addMsg('system', 'Gagal memproses approval: ' + error.message);
    }
  }

  async function loadApprovals() {
    const list = $('#approval-list');
    if (!list) return;
    list.replaceChildren(emptyItem('Memuat approvals…'));
    try {
      const data = await api('/v1/approvals');
      const approvals = Array.isArray(data.approvals) ? data.approvals : [];
      list.replaceChildren();
      if (!approvals.length) {
        list.appendChild(emptyItem('Belum ada permintaan approval.'));
        return;
      }
      for (const approval of approvals) {
        const li = document.createElement('li');
        const title = document.createElement('strong');
        title.textContent = String(approval.tool || 'Tool') + ' · ' + String(approval.risk || 'unknown');
        const meta = document.createElement('p');
        meta.className = 'hint';
        meta.textContent = String(approval.id || '—') + ' · ' + String(approval.state || 'unknown');
        li.append(title, meta);
        if (approval.state === 'pending' && approval.id) {
          const actions = document.createElement('div');
          actions.className = 'row';
          const allow = document.createElement('button');
          allow.type = 'button';
          allow.className = 'primary';
          allow.textContent = 'Izinkan';
          const deny = document.createElement('button');
          deny.type = 'button';
          deny.className = 'danger-button';
          deny.textContent = 'Tolak';
          allow.addEventListener('click', () => decideListedApproval(String(approval.id), true, actions));
          deny.addEventListener('click', () => decideListedApproval(String(approval.id), false, actions));
          actions.append(allow, deny);
          li.appendChild(actions);
        }
        list.appendChild(li);
      }
    } catch (error) {
      list.replaceChildren(emptyItem('Gagal memuat approvals: ' + error.message));
    }
  }

  async function loadSessions() {
    const list = $('#session-list');
    if (!list) return;
    list.replaceChildren(emptyItem('Memuat sessions…'));
    try {
      const data = await api('/v1/sessions');
      const sessions = Array.isArray(data.sessions) ? data.sessions : [];
      list.replaceChildren();
      if (!sessions.length) {
        list.appendChild(emptyItem('Belum ada sesi percakapan.'));
        return;
      }
      for (const session of sessions) {
        const li = document.createElement('li');
        const title = document.createElement('strong');
        title.textContent = String(session.id || 'Sesi tanpa ID');
        const meta = document.createElement('p');
        meta.className = 'hint';
        meta.textContent = String(session.channel || '—') + ' · ' +
          String(session.updated_at || 'belum diperbarui') + ' · turns=' + String(session.turns ?? '—');
        li.append(title, meta);
        list.appendChild(li);
      }
    } catch (error) {
      list.replaceChildren(emptyItem('Gagal memuat sessions: ' + error.message));
    }
  }

  function websocketUrl() {
    const url = new URL(store.base.replace(/\/+$/, '') + '/v1/stream');
    url.protocol = url.protocol === 'https:' ? 'wss:' : 'ws:';
    url.searchParams.set('token', store.token);
    return url.toString();
  }

  function finishTurn() {
    activeTurnFinished = true;
    activeAssistant?.classList.remove('typing');
    if (activeAssistant && ['Menulis…', 'Menulis'].includes(activeAssistant.textContent)) {
      activeAssistant.textContent = '(selesai)';
    }
    setBusy(false);
    if (socket && socket.readyState < WebSocket.CLOSING) socket.close();
    socket = null;
  }

  function handleStreamMessage(raw) {
    const event = JSON.parse(raw);
    switch (event.type) {
      case 'typing':
        if (activeAssistant) {
          activeAssistant.textContent = 'Menulis…';
          activeAssistant.classList.add('typing');
        }
        break;
      case 'text':
        if (activeAssistant) {
          activeAssistant.textContent = String(event.text ?? '');
          activeAssistant.classList.remove('typing');
          msgs.scrollTop = msgs.scrollHeight;
        }
        break;
      case 'confirm':
        showConfirm(String(event.id || ''), String(event.prompt || 'Izinkan tool?'));
        break;
      case 'event': {
        const detail = event.event || {};
        if (detail.type === 'approval.decided' && pendingConfirm?.id === String(detail.id || '')) {
          const state = String(detail.state || 'decided');
          const id = pendingConfirm.id;
          hideConfirm();
          if (state !== 'approved') addMsg('system', 'Persetujuan ' + id + ': ' + state + '.');
        }
        break;
      }
      case 'error':
        if (activeAssistant) {
          activeAssistant.textContent = 'Gagal: ' + String(event.message || 'kesalahan streaming');
          activeAssistant.classList.remove('typing');
        }
        finishTurn();
        break;
      case 'done':
        finishTurn();
        break;
      default:
        break;
    }
  }

  function submitMessage(text) {
    if (!text || busy) return;
    if (!store.token) {
      addMsg('system', 'Masukkan Bearer token pada tab Bantuan → Setelan koneksi terlebih dahulu.');
      return;
    }
    let ws;
    try {
      ws = new WebSocket(websocketUrl());
    } catch (error) {
      addMsg('system', 'Tidak dapat membuka koneksi streaming: ' + error.message);
      return;
    }

    setBusy(true);
    activeTurnFinished = false;
    addMsg('user', text);
    activeAssistant = addMsg('assistant', 'Menulis…');
    activeAssistant.classList.add('typing');
    socket = ws;

    ws.addEventListener('open', () => {
      ws.send(JSON.stringify({ text, session_key: 'web:default', user_key: 'web' }));
    });
    ws.addEventListener('message', (message) => {
      try {
        handleStreamMessage(message.data);
      } catch (error) {
        if (activeAssistant) activeAssistant.textContent = 'Gagal membaca streaming: ' + error.message;
        finishTurn();
      }
    });
    ws.addEventListener('error', () => {
      if (!activeTurnFinished && activeAssistant) {
        activeAssistant.textContent = 'Koneksi streaming gagal. Periksa alamat API, token, dan koneksi daemon.';
        activeAssistant.classList.remove('typing');
      }
      finishTurn();
    });
    ws.addEventListener('close', () => {
      if (!activeTurnFinished) {
        if (activeAssistant) {
          activeAssistant.textContent = 'Koneksi streaming terputus. Periksa status sesi sebelum mengirim ulang agar tindakan tidak terduplikasi.';
          activeAssistant.classList.remove('typing');
        }
        setBusy(false);
        socket = null;
      }
    });
  }

  document.querySelectorAll('.tabs button').forEach((button) => {
    button.addEventListener('click', () => {
      const target = button.dataset.tab;
      document.querySelectorAll('.tabs button').forEach((item) => {
        const active = item === button;
        item.classList.toggle('active', active);
        item.setAttribute('aria-pressed', String(active));
      });
      document.querySelectorAll('.tab').forEach((section) => {
        const active = section.id === 'tab-' + target;
        section.classList.toggle('active', active);
        section.hidden = !active;
      });
      if (target === 'status') loadStatus();
      if (target === 'memory') loadMemory();
      if (target === 'approvals') loadApprovals();
      if (target === 'sessions') loadSessions();
      if (target === 'skills') loadSkills();
      if (target === 'tasks') { loadTasks(); loadLogs(); }
    });
  });

  form.addEventListener('submit', (event) => {
    event.preventDefault();
    const text = input.value.trim();
    if (!text || busy) return;
    input.value = '';
    submitMessage(text);
  });

  $('#saveCfg')?.addEventListener('click', () => {
    try {
      const parsed = new URL(cfgBase.value.trim());
      if (!['http:', 'https:'].includes(parsed.protocol) || !parsed.host || parsed.username || parsed.password) {
        throw new Error('API base harus berupa URL HTTP(S) yang valid.');
      }
      store.base = parsed.toString().replace(/\/+$/, '');
      store.token = cfgToken.value.trim();
      addMsg('system', 'Setelan koneksi disimpan untuk browser ini.');
      ping();
    } catch (error) {
      addMsg('system', error.message || 'Setelan koneksi tidak valid.');
    }
  });

  confirmYes?.addEventListener('click', () => decidePending(true));
  confirmNo?.addEventListener('click', () => decidePending(false));
  $('#refreshStatus')?.addEventListener('click', loadStatus);
  $('#refreshMem')?.addEventListener('click', loadMemory);
  $('#btn-refresh-approvals')?.addEventListener('click', loadApprovals);
  $('#btn-refresh-sessions')?.addEventListener('click', loadSessions);
  $('#btn-refresh-skills')?.addEventListener('click', loadSkills);
  $('#btn-refresh-tasks')?.addEventListener('click', () => { loadTasks(); loadLogs(); });
  $('#btn-refresh-logs')?.addEventListener('click', loadLogs);
  $('#btn-clear-events')?.addEventListener('click', () => {
    eventFeedItems = 0;
    $('#event-feed')?.replaceChildren();
  });
  $('#logSelect')?.addEventListener('change', (event) => {
    loadLogContent(String(event.target?.value || ''));
  });

  addMsg('system', 'Selamat datang di Tiko. Kirim pesan untuk mulai; konfirmasi tool berisiko akan muncul di sini.');
  ping();
  window.setInterval(ping, 15000);
  watchEvents();
})();

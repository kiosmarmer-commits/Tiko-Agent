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

  // GUI-P0-05: token tidak lagi bertahan di localStorage (plaintext permanen).
  // sessionStorage berlaku per-tab dan terhapus saat tab ditutup; token lama
  // dari localStorage dimigrasi sekali lalu dihapus dari penyimpanan permanen.
  const store = {
    get base() { return localStorage.getItem('agent_base') || location.origin; },
    set base(value) { localStorage.setItem('agent_base', value); },
    get token() { return sessionStorage.getItem('agent_token') || ''; },
    set token(value) {
      if (value) sessionStorage.setItem('agent_token', value);
      else sessionStorage.removeItem('agent_token');
      localStorage.removeItem('agent_token');
    },
  };
  const legacyToken = localStorage.getItem('agent_token');
  if (legacyToken && !sessionStorage.getItem('agent_token')) {
    store.token = legacyToken;
  }

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

  async function watchEvents() {
    if (!store.token || watchSocket) return;
    let ws;
    try {
      ws = new WebSocket(await websocketUrl());
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
          if ((type === 'approval.pending' || type === 'approval.decided') && !$('#tab-approvals').hidden) {
            refreshApprovalsFromEvents();
          }
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
      body: JSON.stringify({ approve, actor: 'web' }),
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

  let approvalsEventTimer = null;
  function refreshApprovalsFromEvents() {
    if (approvalsEventTimer) return;
    approvalsEventTimer = window.setTimeout(() => {
      approvalsEventTimer = null;
      loadApprovals();
    }, 250);
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

  // GUI-P1-04 parity: manajemen bot (list, binding, bind/unbind, create, delete).
  async function loadBots() {
    const list = $('#bot-list');
    const bindings = $('#bot-bindings');
    if (!list || !bindings) return;
    list.replaceChildren(emptyItem('Memuat bots\u2026'));
    bindings.replaceChildren(emptyItem('Memuat bindings\u2026'));
    try {
      const [botsData, bindingsData] = await Promise.all([
        api('/v1/bots'),
        api('/v1/bots/bindings'),
      ]);
      const bots = Array.isArray(botsData.bots) ? botsData.bots : [];
      list.replaceChildren();
      if (!bots.length) {
        list.appendChild(emptyItem('Belum ada bot terdaftar.'));
      }
      for (const bot of bots) {
        const li = document.createElement('li');
        const title = document.createElement('strong');
        title.textContent = String(bot.id || 'bot') + ' \u00b7 ' + String(bot.name || '');
        const meta = document.createElement('p');
        meta.className = 'hint';
        meta.textContent = 'persona: ' + String(bot.persona || '(kosong)') +
          ' \u00b7 model: ' + String(bot.model || '(default)') +
          ' \u00b7 allowlist: ' + (Array.isArray(bot.tool_allowlist) && bot.tool_allowlist.length
            ? bot.tool_allowlist.join(', ') : '(kosong \u2014 fail-closed)');
        const actions = document.createElement('div');
        actions.className = 'row';
        const remove = document.createElement('button');
        remove.type = 'button';
        remove.className = 'danger-button';
        remove.textContent = 'Hapus';
        remove.setAttribute('aria-label', 'Hapus bot ' + String(bot.id || ''));
        remove.addEventListener('click', () => deleteBot(String(bot.id), actions));
        actions.append(remove);
        li.append(title, meta, actions);
        list.appendChild(li);
      }
      const map = bindingsData.bindings && typeof bindingsData.bindings === 'object'
        ? bindingsData.bindings : {};
      const pairs = Object.entries(map);
      bindings.replaceChildren();
      if (!pairs.length) {
        bindings.appendChild(emptyItem('Belum ada sesi yang ter-bind ke bot.'));
        return;
      }
      for (const [sessionKey, botId] of pairs) {
        const li = document.createElement('li');
        li.textContent = String(sessionKey) + ' \u2192 ' + String(botId);
        bindings.appendChild(li);
      }
    } catch (error) {
      list.replaceChildren(emptyItem('Gagal memuat bots: ' + error.message));
      bindings.replaceChildren(emptyItem('Gagal memuat bindings: ' + error.message));
    }
  }

  async function deleteBot(id, buttonRow) {
    if (!id) return;
    if (buttonRow) for (const btn of buttonRow.children || []) btn.disabled = true;
    try {
      await api('/v1/bots/' + encodeURIComponent(id), { method: 'DELETE' });
      addMsg('system', 'Bot "' + id + '" dihapus.');
    } catch (error) {
      addMsg('system', 'Gagal menghapus bot: ' + error.message);
    }
    loadBots();
  }

  async function createBot() {
    const idEl = $('#botNewId');
    const nameEl = $('#botNewName');
    if (!idEl || !nameEl) return;
    const id = idEl.value.trim();
    const name = nameEl.value.trim();
    if (!id || !name) {
      addMsg('system', 'ID dan nama bot wajib diisi.');
      return;
    }
    const allowlist = String($('#botNewAllow')?.value || '')
      .split(',')
      .map((tool) => tool.trim())
      .filter(Boolean);
    try {
      await api('/v1/bots', {
        method: 'POST',
        body: JSON.stringify({
          id,
          name,
          persona: String($('#botNewPersona')?.value || '').trim(),
          model: String($('#botNewModel')?.value || '').trim() || null,
          greeting: String($('#botNewGreeting')?.value || '').trim(),
          tool_allowlist: allowlist,
        }),
      });
      addMsg('system', 'Bot "' + id + '" dibuat.');
      idEl.value = '';
      nameEl.value = '';
    } catch (error) {
      addMsg('system', 'Gagal membuat bot: ' + error.message);
    }
    loadBots();
  }

  async function bindOrUnbindBot(bind) {
    const botId = String($('#botBindId')?.value || '').trim();
    const sessionId = String($('#botBindSession')?.value || '').trim();
    if (!botId || !sessionId) {
      addMsg('system', 'ID bot dan Session ID wajib diisi.');
      return;
    }
    try {
      await api('/v1/bots/' + encodeURIComponent(botId) + (bind ? '/bind' : '/unbind'), {
        method: 'POST',
        body: JSON.stringify({ session_id: sessionId }),
      });
      addMsg('system', (bind ? 'Bind' : 'Unbind') + ' sesi "' + sessionId + '" ' +
        (bind ? 'ke' : 'dari') + ' bot "' + botId + '" berhasil.');
    } catch (error) {
      addMsg('system', 'Gagal ' + (bind ? 'bind' : 'unbind') + ': ' + error.message);
    }
    loadBots();
  }

  // GUI-P1-05 parity: provider snapshot read-only + override per sesi.
  async function loadProviders() {
    const list = $('#provider-list');
    if (!list) return;
    list.replaceChildren(emptyItem('Memuat providers\u2026'));
    try {
      const data = await api('/v1/providers');
      const providers = Array.isArray(data.providers) ? data.providers : [];
      list.replaceChildren();
      const heading = document.createElement('li');
      heading.textContent = 'Default: ' + String(data.default || '(tidak diketahui)');
      list.appendChild(heading);
      for (const provider of providers) {
        const li = document.createElement('li');
        const title = document.createElement('strong');
        const caps = provider.capabilities || {};
        title.textContent = String(provider.id || 'provider') +
          (String(provider.id) === String(data.default) ? ' (default)' : '');
        const meta = document.createElement('p');
        meta.className = 'hint';
        meta.textContent = 'tool_calling ' + String(caps.tool_calling === true) +
          ' \u00b7 vision ' + String(caps.vision === true) +
          ' \u00b7 streaming ' + String(caps.streaming === true) +
          ' \u00b7 max_context ' + String(caps.max_context ?? '\u2014') +
          ' \u00b7 health ' + JSON.stringify(provider.health ?? '\u2014');
        li.append(title, meta);
        list.appendChild(li);
      }
      const tiers = data.tiers && typeof data.tiers === 'object' ? data.tiers : {};
      const tierPairs = Object.entries(tiers);
      if (tierPairs.length) {
        const tierItem = document.createElement('li');
        const tierTitle = document.createElement('strong');
        tierTitle.textContent = 'Tiers';
        const tierMeta = document.createElement('p');
        tierMeta.className = 'hint';
        tierMeta.textContent = tierPairs.map(([tier, pid]) => tier + ' \u2192 ' + pid).join(' \u00b7 ');
        tierItem.append(tierTitle, tierMeta);
        list.appendChild(tierItem);
      }
      const overrides = data.session_overrides && typeof data.session_overrides === 'object'
        ? data.session_overrides : {};
      const overridePairs = Object.entries(overrides);
      if (overridePairs.length) {
        const overrideItem = document.createElement('li');
        const overrideTitle = document.createElement('strong');
        overrideTitle.textContent = 'Override sesi aktif';
        const overrideMeta = document.createElement('p');
        overrideMeta.className = 'hint';
        overrideMeta.textContent = overridePairs
          .map(([sessionKey, pid]) => sessionKey + ' \u2192 ' + pid).join(' \u00b7 ');
        overrideItem.append(overrideTitle, overrideMeta);
        list.appendChild(overrideItem);
      }
    } catch (error) {
      list.replaceChildren(emptyItem('Gagal memuat providers: ' + error.message));
    }
  }

  async function applyProviderOverride() {
    const sessionId = String($('#provSessionId')?.value || '').trim();
    const provider = String($('#provOverride')?.value || '').trim();
    if (!sessionId || !provider) {
      addMsg('system', 'Session ID dan provider wajib diisi ("default" untuk reset).');
      return;
    }
    try {
      await api('/v1/providers/session', {
        method: 'POST',
        body: JSON.stringify({ session_id: sessionId, provider }),
      });
      addMsg('system', 'Override provider sesi "' + sessionId + '" \u2192 ' + provider + '.');
    } catch (error) {
      addMsg('system', 'Gagal override: ' + error.message);
    }
    loadProviders();
  }

  // GUI-P1-06 parity: snapshot plugin + consent grant/revoke.
  async function loadPlugins() {
    const list = $('#plugin-list');
    const toolsList = $('#plugin-tools');
    const mcpList = $('#plugin-mcp');
    if (!list || !toolsList || !mcpList) return;
    list.replaceChildren(emptyItem('Memuat plugins\u2026'));
    try {
      const data = await api('/v1/plugins');
      const plugins = Array.isArray(data.plugins) ? data.plugins : [];
      const tools = Array.isArray(data.tools) ? data.tools : [];
      const mcp = data.mcp && typeof data.mcp === 'object' ? data.mcp : {};
      list.replaceChildren();
      if (!plugins.length) {
        list.appendChild(emptyItem('Belum ada plugin terdaftar.'));
      }
      for (const plugin of plugins) {
        const li = document.createElement('li');
        const title = document.createElement('strong');
        title.textContent = String(plugin.id || 'plugin') +
          (plugin.registered ? '' : ' (belum registered)') +
          (plugin.pending ? ' \u00b7 menunggu consent' : '');
        const meta = document.createElement('p');
        meta.className = 'hint';
        meta.textContent = 'granted: ' + (Array.isArray(plugin.granted) && plugin.granted.length
          ? plugin.granted.join(', ') : '(belum ada consent)');
        const actions = document.createElement('div');
        actions.className = 'row';
        const grant = document.createElement('button');
        grant.type = 'button';
        grant.className = 'secondary';
        grant.textContent = 'Setujui';
        grant.addEventListener('click', () => setPluginConsent(String(plugin.id || ''), 'grant', actions));
        const revoke = document.createElement('button');
        revoke.type = 'button';
        revoke.className = 'danger-button';
        revoke.textContent = 'Cabut';
        revoke.addEventListener('click', () => setPluginConsent(String(plugin.id || ''), 'revoke', actions));
        actions.append(grant, revoke);
        li.append(title, meta, actions);
        list.appendChild(li);
      }
      toolsList.replaceChildren();
      if (!tools.length) {
        toolsList.appendChild(emptyItem('Katalog tool kosong.'));
      }
      for (const tool of tools) {
        const li = document.createElement('li');
        const title = document.createElement('strong');
        title.textContent = String(tool.name || 'tool') + ' \u00b7 risk ' + String(tool.risk || 'low');
        const meta = document.createElement('p');
        meta.className = 'hint';
        meta.textContent = String(tool.description || '') +
          ' \u00b7 timeout ' + String(tool.timeout_sec ?? 30) + 's' +
          (tool.parallel_safe ? ' \u00b7 parallel-safe' : '');
        li.append(title, meta);
        toolsList.appendChild(li);
      }
      mcpList.replaceChildren();
      const loader = Array.isArray(mcp.loader) ? mcp.loader : [];
      if (!loader.length) {
        mcpList.appendChild(emptyItem('Tidak ada status server MCP.'));
      }
      for (const status of loader) {
        const li = document.createElement('li');
        const title = document.createElement('strong');
        title.textContent = String(status.server || 'server') + ' \u00b7 ' + String(status.status || 'unknown');
        const meta = document.createElement('p');
        meta.className = 'hint';
        meta.textContent = JSON.stringify(status.detail ?? status.error ?? {}) +
          ' \u00b7 tools ' + String(status.tools ?? '\u2014');
        li.append(title, meta);
        mcpList.appendChild(li);
      }
    } catch (error) {
      list.replaceChildren(emptyItem('Gagal memuat plugins: ' + error.message));
    }
  }

  async function setPluginConsent(plugin, action, buttonRow) {
    if (!plugin) return;
    if (buttonRow) for (const btn of buttonRow.children || []) btn.disabled = true;
    try {
      const result = await api('/v1/plugins/consent', {
        method: 'POST',
        body: JSON.stringify({ plugin, action }),
      });
      addMsg('system', String(result.message || ('Consent ' + action + ' untuk "' + plugin + '".')));
    } catch (error) {
      addMsg('system', 'Gagal consent plugin: ' + error.message);
    }
    loadPlugins();
  }

  // GUI-P1-09 parity: automation / cron CRUD.
  async function loadJobs() {
    const list = $('#job-list');
    if (!list) return;
    list.replaceChildren(emptyItem('Memuat jobs\u2026'));
    try {
      const data = await api('/v1/jobs');
      const jobs = Array.isArray(data.jobs) ? data.jobs : [];
      list.replaceChildren();
      if (!jobs.length) {
        list.appendChild(emptyItem('Belum ada cron job terdaftar.'));
        return;
      }
      for (const job of jobs) {
        const li = document.createElement('li');
        const title = document.createElement('strong');
        title.textContent = String(job.prompt || '(tanpa prompt)') +
          ' \u00b7 cron ' + String(job.cron || '?');
        title.className = 'job-title';
        const badge = document.createElement('span');
        badge.className = job.enabled ? 'pill online' : 'pill offline';
        badge.textContent = job.enabled ? 'ON' : 'OFF';
        const meta = document.createElement('p');
        meta.className = 'hint';
        meta.textContent = 'channel ' + String(job.channel || '-') +
          ' \u00b7 tz ' + String(job.timezone || 'UTC') +
          ' \u00b7 missed ' + String(job.missed_policy || 'runOnce') +
          ' \u00b7 next ' + String(job.next_run || '-') +
          (job.last_run ? ' \u00b7 terakhir ' + String(job.last_run) : '') +
          ' \u00b7 delivery ' + String(job.delivery_state || 'none');
        const actions = document.createElement('div');
        actions.className = 'row';
        const run = document.createElement('button');
        run.type = 'button';
        run.textContent = 'Run now';
        run.setAttribute('aria-label', 'Jalankan sekarang job ' + String(job.id || ''));
        run.addEventListener('click', () => runJobNow(String(job.id)));
        const toggle = document.createElement('button');
        toggle.type = 'button';
        toggle.textContent = job.enabled ? 'Matikan' : 'Aktifkan';
        toggle.setAttribute('aria-label', (job.enabled ? 'Matikan' : 'Aktifkan') + ' job ' + String(job.id || ''));
        toggle.addEventListener('click', () => toggleJob(String(job.id), !job.enabled));
        const remove = document.createElement('button');
        remove.type = 'button';
        remove.className = 'danger-button';
        remove.textContent = 'Hapus';
        remove.setAttribute('aria-label', 'Hapus job ' + String(job.id || ''));
        remove.addEventListener('click', () => deleteJob(String(job.id)));
        actions.append(run, toggle, remove);
        li.append(title, badge, meta, actions);
        list.appendChild(li);
      }
    } catch (error) {
      list.replaceChildren(emptyItem('Gagal memuat jobs: ' + error.message));
    }
  }

  // GUI-P1-10 parity: security center read-only.
  async function loadSecurity() {
    const list = $('#security-box');
    if (!list) return;
    list.replaceChildren(emptyItem('Memuat status keamanan\u2026'));
    try {
      const data = await api('/v1/security');
      list.replaceChildren();
      const safety = data.safety || {};
      const credentials = data.credentials || {};
      const token = data.token_anomaly || {};
      const rate = data.rate_anomaly || {};
      const guard = data.guard || {};
      const audit = data.audit || {};

      const safetyLi = document.createElement('li');
      const safetyTitle = document.createElement('strong');
      safetyTitle.textContent = safety.panic ? 'Safety \u00b7 PANIC aktif'
        : safety.safe_mode ? 'Safety \u00b7 safe mode ON' : 'Safety \u00b7 normal';
      safetyTitle.className = 'job-title';
      const safetyPill = document.createElement('span');
      safetyPill.className = safety.panic || safety.stop_requested ? 'pill offline' : 'pill online';
      safetyPill.textContent = safety.panic ? 'PANIC' : safety.stop_requested ? 'stop request' : 'normal';
      const safetyMeta = document.createElement('p');
      safetyMeta.className = 'hint';
      safetyMeta.textContent = 'sandbox ' + String(data.sandbox || 'unknown') +
        ' \u00b7 kredensial ' + (credentials.sealed_storage ? 'terenkripsi at-rest' : 'plaintext (chmod 600)') +
        ' \u00b7 sesi aktif ' + String(data.active_sessions ?? 0);
      safetyLi.append(safetyTitle, safetyPill, safetyMeta);
      list.appendChild(safetyLi);

      const tokenLi = document.createElement('li');
      const tokenTitle = document.createElement('strong');
      tokenTitle.textContent = 'Token anomaly (E1)';
      tokenTitle.className = 'job-title';
      const tokenMeta = document.createElement('p');
      tokenMeta.className = 'hint';
      const skills = Array.isArray(token.skills) ? token.skills : [];
      tokenMeta.textContent = token.enabled
        ? 'Detektor aktif \u00b7 karantina hari ini ' + String(token.quarantines_today ?? 0) + '/' + String(token.max_quarantines_per_day ?? 0) +
          (skills.length ? ' \u00b7 ' + skills.map((s) => String(s.slug || '?') + ': ' + String(s.samples ?? 0) + ' sampel').join(', ') : '')
        : 'Detektor nonaktif (opt-in via config security.token_anomaly)';
      tokenLi.append(tokenTitle, tokenMeta);
      list.appendChild(tokenLi);

      const plugins = Array.isArray(data.plugins) ? data.plugins : [];
      const pluginsLi = document.createElement('li');
      const pluginsTitle = document.createElement('strong');
      pluginsTitle.textContent = 'Plugin & consent';
      pluginsTitle.className = 'job-title';
      const pluginsMeta = document.createElement('p');
      pluginsMeta.className = 'hint';
      pluginsMeta.textContent = plugins.length
        ? plugins.map((p) => String(p.id || '?') +
            (p.pending ? ' (menunggu consent)' : p.registered ? ' (' + String(p.granted_count ?? 0) + ' izin)' : ' (tidak terdaftar)')).join(', ')
        : 'Tidak ada plugin terdaftar.';
      pluginsLi.append(pluginsTitle, pluginsMeta);
      list.appendChild(pluginsLi);

      const guardLi = document.createElement('li');
      const guardTitle = document.createElement('strong');
      guardTitle.textContent = 'Guard & rate';
      guardTitle.className = 'job-title';
      const guardMeta = document.createElement('p');
      guardMeta.className = 'hint';
      guardMeta.textContent = 'PromptGuard: ' + String(guard.blocked_turns ?? 0) + ' turn diblokir, ' +
        String(guard.sanitized_turns ?? 0) + ' turn disanitasi (sejak start) \u00b7 rate anomaly: >' +
        String(rate.max_events ?? 0) + ' pesan/' + String(rate.window_sec ?? 0) + 's per user dianggap anomali';
      guardLi.append(guardTitle, guardMeta);
      list.appendChild(guardLi);

      const recent = Array.isArray(audit.recent) ? audit.recent : [];
      const auditLi = document.createElement('li');
      const auditTitle = document.createElement('strong');
      auditTitle.textContent = 'Audit terakhir (' + String(audit.total_in_memory ?? 0) + ' entri di memori)';
      auditTitle.className = 'job-title';
      const auditMeta = document.createElement('p');
      auditMeta.className = 'hint';
      auditMeta.textContent = recent.length
        ? recent.slice(0, 15).map((e) => String(e.ts || '-') + ' \u00b7 ' + String(e.tool || '-') +
            ' \u00b7 risk ' + String(e.risk || '-') + ' \u00b7 ' + String(e.verdict || '-') +
            (e.session ? ' \u00b7 ' + String(e.session) : '')).join(' | ')
        : 'Belum ada entri audit.';
      auditLi.append(auditTitle, auditMeta);
      list.appendChild(auditLi);
    } catch (error) {
      list.replaceChildren(emptyItem('Gagal memuat security: ' + error.message));
    }
  }

  // GUI-P1-11 parity: audit query browser (read-only).
  let auditOffset = 0;
  let auditLastLoaded = 0;
  async function loadAuditQuery(resetOffset = false) {
    const list = $('#audit-results');
    if (!list) return;
    const next = $('#btn-audit-next');
    if (resetOffset) auditOffset = 0;
    const params = [];
    const addParam = (key, value) => {
      if (value) params.push(encodeURIComponent(key) + '=' + encodeURIComponent(value));
    };
    addParam('tool', $('#auditTool')?.value?.trim() || '');
    addParam('session', $('#auditSession')?.value?.trim() || '');
    addParam('risk', $('#auditRisk')?.value || '');
    addParam('verdict', $('#auditVerdict')?.value || '');
    if ($('#auditTaint')?.checked) addParam('taint', 'true');
    addParam('limit', '50');
    addParam('offset', String(auditOffset));
    list.replaceChildren(emptyItem('Memuat audit\u2026'));
    try {
      const data = await api('/v1/audit' + (params.length ? '?' + params.join('&') : ''));
      const total = Number(data.total || 0);
      const entries = Array.isArray(data.entries) ? data.entries : [];
      list.replaceChildren();
      const header = document.createElement('li');
      header.className = 'hint';
      header.textContent = total + ' entri cocok \u00b7 menampilkan ' +
        entries.length + ' (offset ' + auditOffset + ')';
      list.appendChild(header);
      if (!entries.length) {
        list.appendChild(emptyItem('Tidak ada entri yang cocok.'));
      }
      for (const entry of entries) {
        const li = document.createElement('li');
        const title = document.createElement('strong');
        title.textContent = String(entry.tool || '-') +
          ' \u00b7 risk ' + String(entry.risk || '-') +
          ' \u00b7 ' + String(entry.verdict || '-');
        title.className = 'job-title';
        const badge = document.createElement('span');
        badge.className = entry.verdict === 'deny' || entry.taint
          ? 'pill offline' : 'pill online';
        badge.textContent = entry.taint ? 'TAINT' : String(entry.risk || '-');
        const meta = document.createElement('p');
        meta.className = 'hint';
        meta.textContent = String(entry.ts || '-') + ' \u00b7 ' +
          String(entry.session || '-') +
          (entry.duration_ms == null ? '' : ' \u00b7 ' + String(entry.duration_ms) + 'ms') +
          (entry.error ? ' \u00b7 error: ' + String(entry.error) : '') +
          (entry.result ? ' \u00b7 ' + String(entry.result) : '');
        li.append(title, badge, meta);
        list.appendChild(li);
      }
      auditLastLoaded = entries.length;
      if (next) next.hidden = entries.length < 50;
    } catch (error) {
      list.replaceChildren(emptyItem('Gagal memuat audit: ' + error.message));
      if (next) next.hidden = true;
    }
  }

  // GUI-P2-04 parity: artifacts browser read-only + diff.
  let artifactsDir = '';
  let artifactContent = null;
  let artifactDiff = null;
  let artifactShowDiff = false;
  function _sizeLabel(bytes) {
    const n = Number(bytes || 0);
    if (n < 1024) return n + ' B';
    if (n < 1024 * 1024) return (n / 1024).toFixed(1) + ' KB';
    return (n / 1024 / 1024).toFixed(1) + ' MB';
  }
  async function loadArtifacts(dir) {
    const list = $('#artifact-list');
    if (!list) return;
    artifactsDir = typeof dir === 'string' ? dir : artifactsDir;
    list.replaceChildren(emptyItem('Memuat artifacts\u2026'));
    try {
      const data = await api('/v1/artifacts' +
        (artifactsDir ? '?dir=' + encodeURIComponent(artifactsDir) : ''));
      const files = Array.isArray(data.files) ? data.files : [];
      list.replaceChildren();
      if (artifactsDir) {
        const up = document.createElement('li');
        const upBtn = document.createElement('button');
        upBtn.type = 'button';
        upBtn.textContent = '.. (naik)';
        upBtn.addEventListener('click', () => {
          const parent = artifactsDir.split('/').slice(0, -1).join('/');
          loadArtifacts(parent);
        });
        up.appendChild(upBtn);
        list.appendChild(up);
      }
      if (!files.length) {
        list.appendChild(emptyItem('Tidak ada file di direktori ini.'));
      }
      for (const file of files) {
        const li = document.createElement('li');
        const title = document.createElement('strong');
        title.textContent = String(file.path || '?');
        const meta = document.createElement('p');
        meta.className = 'hint';
        meta.textContent = _sizeLabel(file.bytes) +
          ' \u00b7 ' + String(file.modified || '-');
        li.append(title, meta);
        li.addEventListener('click', () => openArtifact(
          artifactsDir ? artifactsDir + '/' + String(file.path) : String(file.path)));
        list.appendChild(li);
      }
    } catch (error) {
      list.replaceChildren(emptyItem('Gagal memuat artifacts: ' + error.message));
    }
  }

  function renderArtifactPreview() {
    const box = $('#artifact-preview');
    const title = $('#artifact-preview-title');
    const contentEl = $('#artifact-content');
    const note = $('#artifact-note');
    const toggle = $('#btn-artifact-toggle-diff');
    if (!box || !title || !contentEl || !note) return;
    if (!artifactContent) {
      box.hidden = true;
      return;
    }
    box.hidden = false;
    title.textContent = artifactContent.path || 'Preview';
    if (toggle) {
      toggle.hidden = !artifactDiff;
      toggle.textContent = artifactShowDiff ? 'Preview' : 'Diff';
    }
    if (artifactContent.binary) {
      contentEl.textContent = '(File biner \u2014 pratinjau teks tidak tersedia)';
      if (note) note.textContent = '';
    } else if (artifactShowDiff && artifactDiff) {
      contentEl.textContent = artifactDiff.lines
        .map((l) => (l.type || '=') + ' ' + (l.text || ''))
        .join('\n');
      if (note) {
        note.textContent = artifactDiff.truncated
          ? '\u2026 diff terpotong di batas server' : '';
      }
    } else {
      contentEl.textContent = (artifactContent.content || '') +
        (artifactContent.truncated ? '\n\u2026 (terpotong di batas server)' : '');
      if (note) note.textContent = '';
    }
  }

  async function openArtifact(path) {
    if (!path) {
      artifactContent = null;
      artifactDiff = null;
      artifactShowDiff = false;
      renderArtifactPreview();
      return;
    }
    try {
      artifactContent = await api('/v1/artifacts/read?path=' + encodeURIComponent(path));
      artifactShowDiff = false;
      artifactDiff = null;
      renderArtifactPreview();
      if (artifactContent.bak_exists || artifactContent.bakExists) {
        artifactDiff = await api('/v1/artifacts/diff?path=' + encodeURIComponent(path));
        renderArtifactPreview();
      }
    } catch (error) {
      artifactContent = null;
      artifactDiff = null;
      renderArtifactPreview();
      addMsg('system', 'Gagal membuka file: ' + error.message);
    }
  }

  async function createJobFromWeb() {
    const cronEl = $('#jobNewCron');
    const promptEl = $('#jobNewPrompt');
    if (!cronEl || !promptEl) return;
    const cron = cronEl.value.trim();
    const prompt = promptEl.value.trim();
    if (!cron || !prompt) {
      addMsg('system', 'Cron dan prompt wajib diisi.');
      return;
    }
    const channel = String($('#jobNewChannel')?.value || '').trim();
    const timezone = String($('#jobNewTimezone')?.value || '').trim();
    try {
      await api('/v1/jobs', {
        method: 'POST',
        body: JSON.stringify({
          cron,
          prompt,
          ...(channel ? { channel } : {}),
          ...(timezone ? { timezone } : {}),
        }),
      });
      addMsg('system', 'Cron job dibuat.');
      cronEl.value = '';
      promptEl.value = '';
    } catch (error) {
      addMsg('system', 'Gagal membuat job: ' + error.message);
    }
    loadJobs();
  }

  async function toggleJob(id, enabled) {
    if (!id) return;
    try {
      await api('/v1/jobs/' + encodeURIComponent(id), {
        method: 'PATCH',
        body: JSON.stringify({ enabled }),
      });
      addMsg('system', 'Job "' + id + '" ' + (enabled ? 'diaktifkan' : 'dimatikan') + '.');
    } catch (error) {
      addMsg('system', 'Gagal mengubah job: ' + error.message);
    }
    loadJobs();
  }

  async function runJobNow(id) {
    if (!id) return;
    try {
      await api('/v1/jobs/' + encodeURIComponent(id) + '/run', { method: 'POST' });
      addMsg('system', 'Job "' + id + '" dijadwalkan berjalan pada tick berikutnya (sekitar 20 detik).');
    } catch (error) {
      addMsg('system', 'Gagal memicu job: ' + error.message);
    }
    loadJobs();
  }

  async function deleteJob(id) {
    if (!id) return;
    try {
      await api('/v1/jobs/' + encodeURIComponent(id), { method: 'DELETE' });
      addMsg('system', 'Job "' + id + '" dihapus.');
    } catch (error) {
      addMsg('system', 'Gagal menghapus job: ' + error.message);
    }
    loadJobs();
  }

  // GUI-P1-07 parity: status channel gateway (read-only).
  async function loadChannels() {
    const list = $('#channel-list');
    if (!list) return;
    list.replaceChildren(emptyItem('Memuat channels\u2026'));
    try {
      const data = await api('/v1/channels');
      const channels = Array.isArray(data.channels) ? data.channels : [];
      list.replaceChildren();
      if (!channels.length) {
        list.appendChild(emptyItem('Tidak ada channel terkonfigurasi.'));
        return;
      }
      for (const channel of channels) {
        const li = document.createElement('li');
        const title = document.createElement('strong');
        title.textContent = String(channel.channel || 'channel');
        const badge = document.createElement('span');
        badge.className = channel.active ? 'pill online' : 'pill offline';
        badge.textContent = channel.active ? 'aktif' : 'nonaktif';
        const envList = Array.isArray(channel.env) ? channel.env : [];
        const meta = document.createElement('p');
        meta.className = 'hint';
        meta.textContent = envList.length
          ? 'env: ' + envList.map((name) => String(name)).join(', ')
          : 'env: \u2014';
        li.append(title, badge, meta);
        list.appendChild(li);
      }
    } catch (error) {
      list.replaceChildren(emptyItem('Gagal memuat channels: ' + error.message));
    }
  }

  async function websocketUrl() {
    const root = store.base.replace(/\/+$/, '');
    const url = new URL(root + '/v1/stream');
    url.protocol = url.protocol === 'https:' ? 'wss:' : 'ws:';
    try {
      const res = await fetch(root + '/v1/auth/ticket', {
        method: 'POST',
        headers: { Authorization: 'Bearer ' + store.token },
      });
      if (res.ok) {
        const data = await res.json();
        url.searchParams.set('ticket', data.ticket);
      }
    } catch (error) {
      addMsg('system', 'Gagal mendapatkan ticket stream: ' + error.message);
    }
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
        if (detail.type === 'approval.pending' || detail.type === 'approval.decided') {
          const approvalsVisible = !document.getElementById('tab-approvals')?.hidden;
          if (approvalsVisible) refreshApprovalsFromEvents();
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

  async function submitMessage(text) {
    if (!text || busy) return;
    if (!store.token) {
      addMsg('system', 'Masukkan Bearer token pada tab Bantuan → Setelan koneksi terlebih dahulu.');
      return;
    }
    let ws;
    try {
      ws = new WebSocket(await websocketUrl());
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
      if (target === 'bots') loadBots();
      if (target === 'providers') loadProviders();
      if (target === 'plugins') loadPlugins();
      if (target === 'channels') loadChannels();
      if (target === 'jobs') loadJobs();
      if (target === 'security') loadSecurity();
      if (target === 'audit') loadAuditQuery(true);
      if (target === 'artifacts') loadArtifacts('');
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
  $('#btn-refresh-bots')?.addEventListener('click', loadBots);
  $('#btn-refresh-providers')?.addEventListener('click', loadProviders);
  $('#btn-refresh-plugins')?.addEventListener('click', loadPlugins);
  $('#btn-refresh-channels')?.addEventListener('click', loadChannels);
  $('#btn-refresh-jobs')?.addEventListener('click', loadJobs);
  $('#btn-refresh-security')?.addEventListener('click', loadSecurity);
  $('#btn-audit-query')?.addEventListener('click', () => loadAuditQuery(true));
  $('#btn-audit-next')?.addEventListener('click', () => {
    auditOffset += auditLastLoaded > 0 ? auditLastLoaded : 50;
    loadAuditQuery(false);
  });
  $('#btn-refresh-artifacts')?.addEventListener('click', () => loadArtifacts(artifactsDir));
  $('#btn-artifact-toggle-diff')?.addEventListener('click', () => {
    artifactShowDiff = !artifactShowDiff;
    renderArtifactPreview();
  });
  $('#btn-artifact-close')?.addEventListener('click', () => openArtifact(''));
  $('#jobCreateBtn')?.addEventListener('click', createJobFromWeb);
  $('#botCreateBtn')?.addEventListener('click', createBot);
  $('#botBindBtn')?.addEventListener('click', () => bindOrUnbindBot(true));
  $('#botUnbindBtn')?.addEventListener('click', () => bindOrUnbindBot(false));
  $('#provOverrideBtn')?.addEventListener('click', applyProviderOverride);
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

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');

const source = fs.readFileSync(path.join(__dirname, 'app.js'), 'utf8');

class FakeElement {
  constructor(id = '') {
    this.id = id;
    this.children = [];
    this.listeners = Object.create(null);
    this.attributes = Object.create(null);
    this.dataset = {};
    this.className = '';
    this.value = '';
    this.textContent = '';
    this.hidden = false;
    this.disabled = false;
    this.scrollTop = 0;
    this.scrollHeight = 100;
    this.type = '';
    this.classList = {
      add: (name) => this._setClass(name, true),
      remove: (name) => this._setClass(name, false),
      toggle: (name, force) => {
        const shouldAdd = force === undefined ? !this.classList.contains(name) : Boolean(force);
        this._setClass(name, shouldAdd);
        return shouldAdd;
      },
      contains: (name) => this.className.split(/\s+/).includes(name),
    };
  }
  _setClass(name, add) {
    const classes = new Set(this.className.split(/\s+/).filter(Boolean));
    if (add) classes.add(name); else classes.delete(name);
    this.className = [...classes].join(' ');
  }
  setAttribute(name, value) { this.attributes[name] = String(value); }
  addEventListener(name, callback) {
    (this.listeners[name] ||= []).push(callback);
  }
  dispatch(name, event = {}) {
    for (const callback of this.listeners[name] || []) callback({ preventDefault() {}, ...event });
  }
  appendChild(child) { this.children.push(child); return child; }
  append(...children) { this.children.push(...children); }
  prepend(...children) { this.children.unshift(...children); }
  replaceChildren(...children) { this.children = [...children]; }
  removeChild(child) {
    const index = this.children.indexOf(child);
    if (index >= 0) this.children.splice(index, 1);
    return child;
  }
  get lastChild() { return this.children[this.children.length - 1] ?? null; }
  querySelectorAll(selector) {
    if (selector === 'button') return this.children.filter((item) => item.tagName === 'button');
    return [];
  }
  focus() {}
}

class FakeWebSocket {
  static CLOSING = 2;
  constructor(url) {
    this.url = url;
    this.readyState = 0;
    this.listeners = Object.create(null);
    this.sent = [];
    FakeWebSocket.instances.push(this);
  }
  addEventListener(name, callback) { (this.listeners[name] ||= []).push(callback); }
  fire(name, event = {}) {
    if (name === 'open') this.readyState = 1;
    if (name === 'close') this.readyState = 3;
    for (const callback of this.listeners[name] || []) callback(event);
  }
  send(value) { this.sent.push(value); }
  close() { this.fire('close'); }
}
FakeWebSocket.instances = [];

function createHarness() {
  const ids = [
    'messages', 'chatForm', 'input', 'sendBtn', 'statusPill', 'confirmBox',
    'confirmText', 'confirmYes', 'confirmNo', 'cfgBase', 'cfgToken', 'statusBox',
    'memList', 'approval-list', 'session-list', 'saveCfg', 'refreshStatus',
    'refreshMem', 'btn-refresh-approvals', 'btn-refresh-sessions',
    'task-board', 'event-feed', 'logSelect', 'log-view',
    'btn-refresh-tasks', 'btn-clear-events', 'btn-refresh-logs',
    'bot-list', 'bot-bindings', 'btn-refresh-bots',
    'botBindId', 'botBindSession', 'botBindBtn', 'botUnbindBtn',
    'botNewId', 'botNewName', 'botNewPersona', 'botNewModel',
    'botNewGreeting', 'botNewAllow', 'botCreateBtn',
    'provider-list', 'btn-refresh-providers',
    'provSessionId', 'provOverride', 'provOverrideBtn',
    'plugin-list', 'plugin-tools', 'plugin-mcp', 'btn-refresh-plugins',
    'channel-list', 'btn-refresh-channels',
    'job-list', 'btn-refresh-jobs',
    'jobNewCron', 'jobNewPrompt', 'jobNewChannel', 'jobNewTimezone', 'jobCreateBtn',
    'security-box', 'btn-refresh-security',
  ];
  const elements = Object.fromEntries(ids.map((id) => [id, new FakeElement(id)]));
  elements.confirmBox.classList.add('hidden');
  const tabs = ['chat', 'memory', 'status', 'approvals', 'sessions', 'skills', 'tasks', 'bots', 'providers', 'plugins', 'channels', 'jobs', 'security', 'help'].map((tab) => {
    const element = new FakeElement('tab-button-' + tab);
    element.dataset.tab = tab;
    element.tagName = 'button';
    return element;
  });
  const sections = ['chat', 'memory', 'status', 'approvals', 'sessions', 'skills', 'tasks', 'bots', 'providers', 'plugins', 'channels', 'jobs', 'security', 'help'].map((tab) => {
    const element = new FakeElement('tab-' + tab);
    element.id = 'tab-' + tab;
    element.className = tab === 'chat' ? 'tab active' : 'tab';
    element.hidden = tab !== 'chat';
    return element;
  });
  // $('#tab-xxx') harus mengembalikan elemen section seperti di DOM asli.
  Object.assign(elements, Object.fromEntries(sections.map((section) => [section.id, section])));
  const document = {
    querySelector(selector) {
      if (selector.startsWith('#')) return elements[selector.slice(1)] || null;
      return null;
    },
    querySelectorAll(selector) {
      if (selector === '.tabs button') return tabs;
      if (selector === '.tab') return sections;
      return [];
    },
    createElement(tag) { const element = new FakeElement(); element.tagName = tag; return element; },
  };
  const storage = new Map([['agent_base', 'http://127.0.0.1:8787'], ['agent_token', 's3cr+et & token']]);
  const session = new Map();
  const calls = [];
  const timers = { sync: false };
  const context = {
    document,
    location: { origin: 'http://127.0.0.1:8787' },
    localStorage: {
      getItem: (key) => storage.get(key) ?? null,
      setItem: (key, value) => storage.set(key, String(value)),
      removeItem: (key) => storage.delete(key),
    },
    sessionStorage: {
      getItem: (key) => session.get(key) ?? null,
      setItem: (key, value) => session.set(key, String(value)),
      removeItem: (key) => session.delete(key),
    },
    URL,
    WebSocket: FakeWebSocket,
    window: {
      setInterval: () => 1,
      setTimeout: (fn, _ms) => { if (timers.sync) fn(); return 0; },
    },
    fetch: async (url, options = {}) => {
      calls.push({ url: String(url), options });
      const pathname = new URL(String(url), 'http://127.0.0.1').pathname;
      let body = {};
      if (pathname === '/v1/auth/ticket') body = { ticket: 'test-ticket' };
      else if (pathname === '/v1/status') body = { provider: 'mock' };
      else if (pathname === '/v1/memories') body = { memories: [{ kind: '<img src=x onerror=alert(1)>', importance: '<b>high</b>', text: '<script>alert(1)</script>' }] };
      else if (pathname === '/v1/approvals') body = { approvals: [{ id: 'apr_1', state: 'pending', tool: 'write_file', risk: 'high' }] };
      else if (pathname === '/v1/sessions') body = { sessions: [{ id: 'web:default', channel: 'http', turns: 2 }] };
      else if (pathname.startsWith('/v1/approvals/')) body = { ok: true };
      else if (pathname === '/v1/tasks') body = { tasks: [
        { id: 'kb-1', title: '<script>alert(1)</script>', state: 'doing', claimed_by: 'agent', result: '' },
        { id: 'kb-2', title: 'rapikan README', state: 'done', claimed_by: '', result: 'selesai' },
      ] };
      else if (pathname === '/v1/logs') body = { logs: [{ name: 'audit-20261113.jsonl', bytes: 42 }] };
      else if (pathname.startsWith('/v1/logs/')) body = { name: decodeURIComponent(pathname.slice('/v1/logs/'.length)), bytes: 42, truncated: true, content: '<img src=x onerror=alert(1)>\n{"tool":"shell"}' };
      else if (pathname === '/v1/bots') body = { bots: [{ id: 'assistant', name: '<script>alert(1)</script>', persona: 'ringkas', model: null, tool_allowlist: ['read_file'], created_at: '2026-11-18T00:00:00.000Z' }] };
      else if (pathname === '/v1/bots/bindings') body = { bindings: { 'web:default': 'assistant' } };
      else if (pathname.startsWith('/v1/bots/')) body = { deleted: true, ok: true };
      else if (pathname === '/v1/providers') body = {
        default: 'mock-1',
        providers: [{ id: 'mock-1', capabilities: { tool_calling: true, vision: false, streaming: true, max_context: 32000 }, health: { ok: true } }],
        tiers: { reasoner: 'mock-2' },
        session_overrides: { 'web:default': 'mock-2' },
      };
      else if (pathname === '/v1/providers/session') body = { ok: true, session_id: 'web:default', provider: 'mock-2' };
      else if (pathname === '/v1/plugins') body = {
        plugins: [{ id: 'echo', registered: true, pending: false, granted: ['shell'], requested: ['shell'] }],
        events: [],
        tools: [{ name: 'shell', description: 'eksekusi', risk: 'high', timeout_sec: 30, parallel_safe: false }],
        mcp: { started: true, loader: [{ server: 'demo', status: 'ready', tools: 3 }] },
      };
      else if (pathname === '/v1/plugins/consent') body = { ok: true, message: 'Consent diberikan.' };
      else if (pathname === '/v1/channels') body = { channels: [{ channel: 'telegram', active: true, env: ['TG_TOKEN', 'TG_ALLOW'] }, { channel: 'slack', active: false, env: ['SLACK_BOT_TOKEN'] }] };
      else if (pathname === '/v1/jobs') body = { jobs: [
        { id: 'job-1', cron: '*/5 * * * *', prompt: '<script>alert(1)</script>ringkas berita', channel: 'http', enabled: true, missed_policy: 'runOnce', timezone: 'UTC', next_run: '2026-11-18T13:00:00.000Z', delivery_state: 'none' },
        { id: 'job-2', cron: '0 9 * * *', prompt: 'backup harian', channel: 'telegram', enabled: false, missed_policy: 'skip', timezone: 'Asia/Jakarta', next_run: '2026-11-19T02:00:00.000Z', delivery_state: 'delivered' },
      ] };
      else if (pathname === '/v1/jobs/job-1/run') body = { id: 'job-1', next_run: '2026-11-18T13:01:00.000Z', enabled: true };
      else if (pathname.startsWith('/v1/jobs/')) body = { deleted: true, ok: true };
      else if (pathname === '/v1/security') body = {
        safety: { safe_mode: true, panic: false, stop_requested: false },
        sandbox: 'landlock',
        credentials: { sealed_storage: true },
        plugins: [{ id: 'weather', registered: true, pending: false, granted_count: 3, requested_count: 3 }],
        token_anomaly: { enabled: true, quarantines_today: 1, max_quarantines_per_day: 5, skills: [{ slug: 'berita', samples: 42 }] },
        rate_anomaly: { window_sec: 60, max_events: 40 },
        guard: { blocked_turns: 2, sanitized_turns: 7 },
        audit: { total_in_memory: 320, recent: [{ ts: '2026-11-18T13:00:00.000Z', tool: 'shell.exec', risk: 'high', verdict: 'allowed', session: 's-1' }] },
        active_sessions: 2,
      };
      return { ok: true, status: 200, json: async () => body, text: async () => '' };
    },
  };
  vm.runInNewContext(source, context, { filename: 'app.js' });
  return { elements, tabs, sections, calls, storage, session, timers };
}

const tick = () => new Promise((resolve) => setImmediate(resolve));

test('Approvals and Sessions tabs load their API data and are not left hidden', async () => {
  const h = createHarness();
  h.tabs.find((tab) => tab.dataset.tab === 'approvals').dispatch('click');
  await tick();
  assert.equal(h.sections.find((section) => section.id === 'tab-approvals').hidden, false);
  assert.ok(h.calls.some((call) => call.url.endsWith('/v1/approvals')));
  assert.equal(h.elements['approval-list'].children[0].children[0].textContent, 'write_file · high');

  h.tabs.find((tab) => tab.dataset.tab === 'sessions').dispatch('click');
  await tick();
  assert.equal(h.sections.find((section) => section.id === 'tab-sessions').hidden, false);
  assert.ok(h.calls.some((call) => call.url.endsWith('/v1/sessions')));
  assert.equal(h.elements['session-list'].children[0].children[0].textContent, 'web:default');
});

test('GUI-P0-05: token dimigrasi dari localStorage ke sessionStorage dan tidak bertahan permanen', async () => {
  const h = createHarness();
  assert.equal(h.storage.has('agent_token'), false);
  assert.equal(h.session.get('agent_token'), 's3cr+et & token');

  // Simpan token baru lewat form konfigurasi: masuk ke sessionStorage,
  // bukan localStorage; token kosong menghapus sesi.
  h.elements.cfgBase.value = 'http://127.0.0.1:8787';
  h.elements.cfgToken.value = 'token-baru';
  h.elements.saveCfg.dispatch('click');
  assert.equal(h.session.get('agent_token'), 'token-baru');
  assert.equal(h.storage.has('agent_token'), false);

  h.elements.cfgToken.value = '';
  h.elements.saveCfg.dispatch('click');
  assert.equal(h.session.has('agent_token'), false);
});

test('Memory content is rendered as text, never interpolated as HTML', async () => {
  const h = createHarness();
  h.tabs.find((tab) => tab.dataset.tab === 'memory').dispatch('click');
  await tick();
  const item = h.elements.memList.children[0];
  assert.equal(item.children[0].textContent, '<img src=x onerror=alert(1)>');
  assert.equal(item.children[1].textContent, ' · prioritas <b>high</b>');
  assert.equal(item.children[2].textContent, '<script>alert(1)</script>');
});

test('Chat streams over one-time-ticket WebSocket and the shared approval API', async () => {
  const h = createHarness();
  h.elements.input.value = 'buat file';
  h.elements.chatForm.dispatch('submit');
  await tick();
  await tick();
  const ws = FakeWebSocket.instances.at(-1);
  const url = new URL(ws.url);
  assert.equal(url.searchParams.get('ticket'), 'test-ticket');
  assert.equal(url.searchParams.get('token'), null);
  assert.ok(!ws.url.includes(encodeURIComponent('s3cr+et & token')), 'token mentah tidak boleh ada di URL stream');
  assert.ok(h.calls.some((call) => call.url.endsWith('/v1/auth/ticket') && call.options.method === 'POST' && call.options.headers.Authorization === 'Bearer s3cr+et & token'));
  ws.fire('open');
  assert.equal(JSON.parse(ws.sent[0]).text, 'buat file');
  ws.fire('message', { data: JSON.stringify({ type: 'confirm', id: 'apr_1', prompt: 'Izinkan write_file?' }) });
  assert.equal(h.elements.confirmBox.classList.contains('hidden'), false);
  h.elements.confirmYes.dispatch('click');
  await tick();
  assert.ok(h.calls.some((call) => call.url.endsWith('/v1/approvals/apr_1') && call.options.method === 'POST'));
  const decisionCall = h.calls.find((call) => call.url.endsWith('/v1/approvals/apr_1') && call.options.method === 'POST');
  assert.equal(JSON.parse(decisionCall.options.body).actor, 'web');
  assert.equal(h.elements.confirmBox.classList.contains('hidden'), true);
  ws.fire('message', { data: JSON.stringify({ type: 'text', text: 'Selesai.' }) });
  ws.fire('message', { data: JSON.stringify({ type: 'done' }) });
  assert.equal(h.elements.sendBtn.disabled, false);
});

test('GUI-P0-06: event approval dari client lain memicu reload daftar approvals saat tab aktif', async () => {
  const h = createHarness();
  h.tabs.find((tab) => tab.dataset.tab === 'approvals').dispatch('click');
  await tick();
  const callsBefore = h.calls.filter((call) => call.url.endsWith('/v1/approvals')).length;

  h.timers.sync = true;
  const watcher = FakeWebSocket.instances.at(-1);
  watcher.fire('open');
  watcher.fire('message', { data: JSON.stringify({ type: 'event', event: { type: 'approval.decided', id: 'apr_1', state: 'approved', actor: 'flutter' } }) });
  await tick();
  const callsAfter = h.calls.filter((call) => call.url.endsWith('/v1/approvals')).length;
  assert.ok(callsAfter > callsBefore, 'daftar approvals dimuat ulang saat event decided masuk');

  const watchedBefore = h.calls.filter((call) => call.url.endsWith('/v1/approvals')).length;
  watcher.fire('message', { data: JSON.stringify({ type: 'event', event: { type: 'approval.pending', id: 'apr_2', tool: 'write_file' } }) });
  await tick();
  assert.ok(h.calls.filter((call) => call.url.endsWith('/v1/approvals')).length > watchedBefore, 'event pending juga memicu reload');
});

test('GUI-P0-06: event approval diabaikan saat tab approvals tidak aktif', async () => {
  const h = createHarness();
  h.timers.sync = true;
  await tick();
  await tick();
  const watcher = FakeWebSocket.instances.at(-1);
  watcher.fire('open');
  const callsBefore = h.calls.filter((call) => call.url.endsWith('/v1/approvals')).length;
  watcher.fire('message', { data: JSON.stringify({ type: 'event', event: { type: 'approval.decided', id: 'apr_9', state: 'denied', actor: 'flutter' } }) });
  await tick();
  assert.equal(h.calls.filter((call) => call.url.endsWith('/v1/approvals')).length, callsBefore, 'tab chat aktif: approvals tidak dimuat ulang');
});

test('Tasks tab renders the kanban board, log list, and log content as text', async () => {
  const h = createHarness();
  h.tabs.find((tab) => tab.dataset.tab === 'tasks').dispatch('click');
  await tick();
  await tick();
  assert.equal(h.sections.find((section) => section.id === 'tab-tasks').hidden, false);
  assert.ok(h.calls.some((call) => call.url.endsWith('/v1/tasks')));
  assert.ok(h.calls.some((call) => call.url.endsWith('/v1/logs')));
  const board = h.elements['task-board'];
  assert.equal(board.children.length, 4);
  const doing = board.children.find((col) => col.className.includes('board-col-doing'));
  assert.equal(doing.children[1].children[0].textContent, '<script>alert(1)</script>');
  const logView = h.elements['log-view'];
  assert.ok(logView.textContent.includes('<img src=x onerror=alert(1)>'));
  assert.ok(logView.textContent.includes('[dipotong, 64KB terakhir]'));
});

test('Live event watcher appends streamed events to the event feed', async () => {
  const h = createHarness();
  await tick();
  await tick();
  const watcher = FakeWebSocket.instances.at(-1);
  assert.ok(watcher, 'watcher socket dibuka saat load');
  watcher.fire('open');
  watcher.fire('message', { data: JSON.stringify({ type: 'event', event: { type: 'job.completed', at: '2026-11-13T02:00:00.000Z', id: 'jb-9' } }) });
  const feed = h.elements['event-feed'];
  assert.equal(feed.children.length, 1);
  assert.equal(feed.children[0].children[0].textContent, 'job.completed');
  watcher.fire('message', { data: 'bukan-json' });
  assert.equal(feed.children.length, 1);
});

test('Bots tab memuat daftar bot, binding, dan aksi hapus memanggil DELETE', async () => {
  const h = createHarness();
  h.tabs.find((tab) => tab.dataset.tab === 'bots').dispatch('click');
  await tick();
  await tick();
  assert.equal(h.sections.find((section) => section.id === 'tab-bots').hidden, false);
  assert.ok(h.calls.some((call) => call.url.endsWith('/v1/bots')));
  assert.ok(h.calls.some((call) => call.url.endsWith('/v1/bots/bindings')));
  const item = h.elements['bot-list'].children[0];
  assert.equal(item.children[0].textContent, 'assistant \u00b7 <script>alert(1)</script>');
  assert.equal(item.children[1].textContent, 'persona: ringkas \u00b7 model: (default) \u00b7 allowlist: read_file');
  assert.equal(h.elements['bot-bindings'].children[0].textContent, 'web:default \u2192 assistant');

  const deleteBtn = item.children[2].children[0];
  deleteBtn.dispatch('click');
  await tick();
  await tick();
  assert.ok(h.calls.some((call) => call.url.endsWith('/v1/bots/assistant') && call.options.method === 'DELETE'));
});

test('Buat bot mengirim POST /v1/bots dan bind/unbind sesi', async () => {
  const h = createHarness();
  h.elements.botNewId.value = 'writer';
  h.elements.botNewName.value = 'Penulis';
  h.elements.botNewPersona.value = 'Detail';
  h.elements.botNewAllow.value = 'read_file, shell';
  h.elements.botCreateBtn.dispatch('click');
  await tick();
  await tick();
  const createCall = h.calls.find((call) => call.url.endsWith('/v1/bots') && call.options.method === 'POST');
  assert.ok(createCall, 'POST /v1/bots terkirim');
  const payload = JSON.parse(createCall.options.body);
  assert.deepEqual(payload.tool_allowlist, ['read_file', 'shell']);
  assert.equal(payload.model, null);

  h.elements.botBindId.value = 'writer';
  h.elements.botBindSession.value = 'web:default';
  h.elements.botBindBtn.dispatch('click');
  await tick();
  await tick();
  const bindCall = h.calls.find((call) => call.url.endsWith('/v1/bots/writer/bind') && call.options.method === 'POST');
  assert.equal(JSON.parse(bindCall.options.body).session_id, 'web:default');

  h.elements.botUnbindBtn.dispatch('click');
  await tick();
  await tick();
  assert.ok(h.calls.some((call) => call.url.endsWith('/v1/bots/writer/unbind') && call.options.method === 'POST'));
});

test('Provider tab memuat snapshot dan override mengirim POST /v1/providers/session', async () => {
  const h = createHarness();
  h.tabs.find((tab) => tab.dataset.tab === 'providers').dispatch('click');
  await tick();
  await tick();
  assert.equal(h.sections.find((section) => section.id === 'tab-providers').hidden, false);
  assert.ok(h.calls.some((call) => call.url.endsWith('/v1/providers')));
  const first = h.elements['provider-list'].children[0];
  assert.equal(first.textContent, 'Default: mock-1');
  const item = h.elements['provider-list'].children[1];
  assert.ok(item.children[0].textContent.includes('mock-1 (default)'));
  assert.ok(item.children[1].textContent.includes('mock-2') === false);

  h.elements.provSessionId.value = 'web:default';
  h.elements.provOverride.value = 'mock-2';
  h.elements.provOverrideBtn.dispatch('click');
  await tick();
  await tick();
  const overrideCall = h.calls.find((call) => call.url.endsWith('/v1/providers/session') && call.options.method === 'POST');
  assert.deepEqual(JSON.parse(overrideCall.options.body), { session_id: 'web:default', provider: 'mock-2' });
});

test('Plugin tab memuat snapshot dan consent memanggil POST /v1/plugins/consent', async () => {
  const h = createHarness();
  h.tabs.find((tab) => tab.dataset.tab === 'plugins').dispatch('click');
  await tick();
  await tick();
  assert.equal(h.sections.find((section) => section.id === 'tab-plugins').hidden, false);
  assert.ok(h.calls.some((call) => call.url.endsWith('/v1/plugins')));
  const item = h.elements['plugin-list'].children[0];
  assert.ok(item.children[0].textContent.includes('echo'));
  assert.ok(item.children[1].textContent.includes('shell'));
  assert.equal(h.elements['plugin-tools'].children[0].children[0].textContent, 'shell \u00b7 risk high');
  assert.ok(h.elements['plugin-mcp'].children[0].children[0].textContent.includes('ready'));

  const grant = item.children[2].children[0];
  grant.dispatch('click');
  await tick();
  await tick();
  const consentCall = h.calls.find((call) => call.url.endsWith('/v1/plugins/consent') && call.options.method === 'POST');
  assert.deepEqual(JSON.parse(consentCall.options.body), { plugin: 'echo', action: 'grant' });
});

test('Channels tab read-only menampilkan badge aktif dan nama env', async () => {
  const h = createHarness();
  h.tabs.find((tab) => tab.dataset.tab === 'channels').dispatch('click');
  await tick();
  await tick();
  assert.equal(h.sections.find((section) => section.id === 'tab-channels').hidden, false);
  assert.ok(h.calls.some((call) => call.url.endsWith('/v1/channels')));
  const active = h.elements['channel-list'].children[0];
  assert.equal(active.children[0].textContent, 'telegram');
  assert.equal(active.children[1].className, 'pill online');
  assert.equal(active.children[1].textContent, 'aktif');
  assert.equal(active.children[2].textContent, 'env: TG_TOKEN, TG_ALLOW');
  const inactive = h.elements['channel-list'].children[1];
  assert.equal(inactive.children[1].className, 'pill offline');
  assert.equal(inactive.children[1].textContent, 'nonaktif');
});

test('Automation tab memuat daftar job dengan badge ON/OFF dan XSS-dicegah', async () => {
  const h = createHarness();
  h.tabs.find((tab) => tab.dataset.tab === 'jobs').dispatch('click');
  await tick();
  await tick();
  assert.equal(h.sections.find((section) => section.id === 'tab-jobs').hidden, false);
  assert.ok(h.calls.some((call) => call.url.endsWith('/v1/jobs')));
  const first = h.elements['job-list'].children[0];
  // Render aman textContent: markup alert tidak boleh menjadi elemen nyata.
  assert.equal(first.children[0].textContent, '<script>alert(1)</script>ringkas berita · cron */5 * * * *');
  assert.ok(!first.querySelector || !first.innerHTML?.includes('<script>'));
  assert.equal(first.children[1].className, 'pill online');
  assert.equal(first.children[1].textContent, 'ON');
  const second = h.elements['job-list'].children[1];
  assert.equal(second.children[1].className, 'pill offline');
  assert.equal(second.children[1].textContent, 'OFF');
  assert.ok(second.children[3].textContent.includes('Skip aktif') === false);
  assert.ok(first.children[2].textContent.includes('delivery none'));
});

test('Run now mengirim POST /v1/jobs/:id/run, toggle mengirim PATCH enabled', async () => {
  const h = createHarness();
  h.tabs.find((tab) => tab.dataset.tab === 'jobs').dispatch('click');
  await tick();
  await tick();
  const first = h.elements['job-list'].children[0];
  const runBtn = first.children[3].children.find((btn) => btn.textContent === 'Run now');
  runBtn.dispatch('click');
  await tick();
  await tick();
  assert.ok(h.calls.some((call) => call.url.endsWith('/v1/jobs/job-1/run') && call.options.method === 'POST'));

  const second = h.elements['job-list'].children[1];
  const toggleBtn = second.children[3].children.find((btn) => btn.textContent === 'Aktifkan');
  toggleBtn.dispatch('click');
  await tick();
  await tick();
  const patch = h.calls.find((call) => call.options.method === 'PATCH');
  assert.ok(patch, 'PATCH terkirim');
  assert.ok(patch.url.endsWith('/v1/jobs/job-2'));
  assert.deepEqual(JSON.parse(patch.options.body), { enabled: true });
});

test('Buat cron job mengirim POST /v1/jobs dengan cron + prompt wajib', async () => {
  const h = createHarness();
  h.tabs.find((tab) => tab.dataset.tab === 'jobs').dispatch('click');
  await tick();
  await tick();

  // Cron kosong ditolak tanpa POST.
  h.elements['jobCreateBtn'].dispatch('click');
  await tick();
  assert.ok(!h.calls.some((call) => call.options.method === 'POST' && call.url.endsWith('/v1/jobs')));

  h.elements['jobNewCron'].value = '0 9 * * *';
  h.elements['jobNewPrompt'].value = 'laporan harian';
  h.elements['jobNewChannel'].value = 'telegram';
  h.elements['jobNewTimezone'].value = 'Asia/Jakarta';
  h.elements['jobCreateBtn'].dispatch('click');
  await tick();
  await tick();
  const create = h.calls.find((call) => call.options.method === 'POST' && call.url.endsWith('/v1/jobs'));
  assert.ok(create, 'POST /v1/jobs terkirim');
  assert.deepEqual(JSON.parse(create.options.body), {
    cron: '0 9 * * *',
    prompt: 'laporan harian',
    channel: 'telegram',
    timezone: 'Asia/Jakarta',
  });
});

test('Security tab memuat snapshot read-only dengan status safety', async () => {
  const h = createHarness();
  h.tabs.find((tab) => tab.dataset.tab === 'security').dispatch('click');
  await tick();
  await tick();
  assert.equal(h.sections.find((section) => section.id === 'tab-security').hidden, false);
  assert.ok(h.calls.some((call) => call.url.endsWith('/v1/security')));
  const items = h.elements['security-box'].children;
  assert.equal(items.length, 5);
  assert.equal(items[0].children[0].textContent, 'Safety · safe mode ON');
  assert.equal(items[0].children[1].textContent, 'normal');
  assert.ok(items[0].children[2].textContent.includes('sandbox landlock'));
  assert.ok(items[0].children[2].textContent.includes('sesi aktif 2'));
  assert.ok(items[1].children[1].textContent.includes('karantina hari ini 1/5'));
  assert.ok(items[1].children[1].textContent.includes('berita: 42 sampel'));
  assert.ok(items[2].children[1].textContent.includes('weather (3 izin)'));
  assert.ok(items[3].children[1].textContent.includes('2 turn diblokir'));
  assert.ok(items[4].children[1].textContent.includes('shell.exec'));
});

test('Tombol refresh security memanggil ulang GET /v1/security', async () => {
  const h = createHarness();
  h.tabs.find((tab) => tab.dataset.tab === 'security').dispatch('click');
  await tick();
  await tick();
  const before = h.calls.filter((call) => call.url.endsWith('/v1/security')).length;
  h.elements['btn-refresh-security'].dispatch('click');
  await tick();
  await tick();
  const after = h.calls.filter((call) => call.url.endsWith('/v1/security')).length;
  assert.ok(after > before, 'GET /v1/security dipanggil ulang');
});

test('Hapus job mengirim DELETE /v1/jobs/:id', async () => {
  const h = createHarness();
  h.tabs.find((tab) => tab.dataset.tab === 'jobs').dispatch('click');
  await tick();
  await tick();
  const first = h.elements['job-list'].children[0];
  const removeBtn = first.children[3].children.find((btn) => btn.textContent === 'Hapus');
  removeBtn.dispatch('click');
  await tick();
  await tick();
  assert.ok(h.calls.some((call) => call.url.endsWith('/v1/jobs/job-1') && call.options.method === 'DELETE'));
});

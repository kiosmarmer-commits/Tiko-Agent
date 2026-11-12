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
  replaceChildren(...children) { this.children = [...children]; }
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
  ];
  const elements = Object.fromEntries(ids.map((id) => [id, new FakeElement(id)]));
  elements.confirmBox.classList.add('hidden');
  const tabs = ['chat', 'memory', 'status', 'approvals', 'sessions', 'help'].map((tab) => {
    const element = new FakeElement('tab-button-' + tab);
    element.dataset.tab = tab;
    element.tagName = 'button';
    return element;
  });
  const sections = ['chat', 'memory', 'status', 'approvals', 'sessions', 'help'].map((tab) => {
    const element = new FakeElement('tab-' + tab);
    element.id = 'tab-' + tab;
    element.className = tab === 'chat' ? 'tab active' : 'tab';
    element.hidden = tab !== 'chat';
    return element;
  });
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
  const calls = [];
  const context = {
    document,
    location: { origin: 'http://127.0.0.1:8787' },
    localStorage: {
      getItem: (key) => storage.get(key) ?? null,
      setItem: (key, value) => storage.set(key, String(value)),
    },
    URL,
    WebSocket: FakeWebSocket,
    window: { setInterval: () => 1 },
    fetch: async (url, options = {}) => {
      calls.push({ url: String(url), options });
      const pathname = new URL(String(url), 'http://127.0.0.1').pathname;
      let body = {};
      if (pathname === '/v1/status') body = { provider: 'mock' };
      else if (pathname === '/v1/memories') body = { memories: [{ kind: '<img src=x onerror=alert(1)>', importance: '<b>high</b>', text: '<script>alert(1)</script>' }] };
      else if (pathname === '/v1/approvals') body = { approvals: [{ id: 'apr_1', state: 'pending', tool: 'write_file', risk: 'high' }] };
      else if (pathname === '/v1/sessions') body = { sessions: [{ id: 'web:default', channel: 'http', turns: 2 }] };
      else if (pathname.startsWith('/v1/approvals/')) body = { ok: true };
      return { ok: true, status: 200, json: async () => body, text: async () => '' };
    },
  };
  vm.runInNewContext(source, context, { filename: 'app.js' });
  return { elements, tabs, sections, calls, storage };
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

test('Memory content is rendered as text, never interpolated as HTML', async () => {
  const h = createHarness();
  h.tabs.find((tab) => tab.dataset.tab === 'memory').dispatch('click');
  await tick();
  const item = h.elements.memList.children[0];
  assert.equal(item.children[0].textContent, '<img src=x onerror=alert(1)>');
  assert.equal(item.children[1].textContent, ' · prioritas <b>high</b>');
  assert.equal(item.children[2].textContent, '<script>alert(1)</script>');
});

test('Chat uses encoded-token WebSocket streaming and the shared approval API', async () => {
  const h = createHarness();
  h.elements.input.value = 'buat file';
  h.elements.chatForm.dispatch('submit');
  const ws = FakeWebSocket.instances.at(-1);
  assert.equal(new URL(ws.url).searchParams.get('token'), 's3cr+et & token');
  ws.fire('open');
  assert.equal(JSON.parse(ws.sent[0]).text, 'buat file');
  ws.fire('message', { data: JSON.stringify({ type: 'confirm', id: 'apr_1', prompt: 'Izinkan write_file?' }) });
  assert.equal(h.elements.confirmBox.classList.contains('hidden'), false);
  h.elements.confirmYes.dispatch('click');
  await tick();
  assert.ok(h.calls.some((call) => call.url.endsWith('/v1/approvals/apr_1') && call.options.method === 'POST'));
  assert.equal(h.elements.confirmBox.classList.contains('hidden'), true);
  ws.fire('message', { data: JSON.stringify({ type: 'text', text: 'Selesai.' }) });
  ws.fire('message', { data: JSON.stringify({ type: 'done' }) });
  assert.equal(h.elements.sendBtn.disabled, false);
});

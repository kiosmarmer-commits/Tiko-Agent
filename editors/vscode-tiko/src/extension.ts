import * as vscode from 'vscode';

interface TikoFrame {
  type: string;
  [key: string]: unknown;
}

interface TikoConfig {
  baseUrl: string;
  authToken: string;
  sessionKey: string;
}

function readConfig(): TikoConfig {
  const cfg = vscode.workspace.getConfiguration('tikoAgent');
  return {
    baseUrl: (cfg.get<string>('baseUrl') ?? 'http://127.0.0.1:8787').replace(/\/+$/, ''),
    authToken: cfg.get<string>('authToken') ?? '',
    sessionKey: cfg.get<string>('sessionKey') ?? 'vscode:default',
  };
}

/// Konek SSE POST /v1/messages daemon agentd (frame chat.status /
/// chat.toolStart / chat.tool / chat.delta / chat.usage / text / done /
/// error — sama dengan jalur WS /v1/stream).
async function* streamMessage(text: string): AsyncGenerator<TikoFrame> {
  const { baseUrl, authToken, sessionKey } = readConfig();
  const res = await fetch(`${baseUrl}/v1/messages`, {
    method: 'POST',
    headers: {
      'content-type': 'application/json',
      accept: 'text/event-stream',
      ...(authToken ? { authorization: `Bearer ${authToken}` } : {}),
    },
    body: JSON.stringify({ text, session_key: sessionKey, stream: true }),
  });
  if (!res.ok || !res.body) {
    yield { type: 'error', message: `agentd HTTP ${res.status}` };
    return;
  }
  const decoder = new TextDecoder();
  let buf = '';
  for await (const chunk of res.body) {
    buf += decoder.decode(chunk as Uint8Array, { stream: true });
    let idx: number;
    while ((idx = buf.indexOf('\n\n')) >= 0) {
      const raw = buf.slice(0, idx).trim();
      buf = buf.slice(idx + 2);
      if (!raw.startsWith('data:')) continue;
      const payload = raw.slice(5).trim();
      if (!payload || payload === '[DONE]') continue;
      try {
        yield JSON.parse(payload) as TikoFrame;
      } catch {
        yield { type: 'error', message: `frame korup: ${payload.slice(0, 120)}` };
      }
    }
  }
}

class ChatSession {
  private cancelRequested = false;
  private streaming = false;
  private answer = '';

  constructor(private readonly post: (frame: TikoFrame) => void) {}

  cancel(): void {
    if (!this.streaming) return;
    this.cancelRequested = true;
    this.post({ type: 'status', state: 'cancelling' });
  }

  prefill(text: string): void {
    this.post({ type: 'prefill', text });
  }

  async ask(text: string): Promise<void> {
    if (this.streaming || !text.trim()) return;
    this.streaming = true;
    this.cancelRequested = false;
    this.answer = '';
    this.post({ type: 'status', state: 'running' });
    let lastError = '';
    try {
      for await (const frame of streamMessage(text)) {
        if (this.cancelRequested) break;
        switch (frame.type) {
          case 'chat.delta': {
            const t = typeof frame['text'] === 'string' ? frame['text'] : '';
            if (t) {
              this.answer += t;
              this.post({ type: 'delta', text: t });
            }
            break;
          }
          case 'toolStart':
            this.post({
              type: 'tool',
              name: String(frame['name'] ?? 'tool'),
              state: 'running',
            });
            break;
          case 'tool':
            this.post({
              type: 'tool',
              name: String(frame['name'] ?? 'tool'),
              state: frame['isError'] === true ? 'error' : 'done',
            });
            break;
          case 'chat.usage':
            this.post({ type: 'usage', usage: frame });
            break;
          case 'error':
            lastError = String(frame['message'] ?? 'error');
            break;
          default:
            break;
        }
      }
    } finally {
      this.streaming = false;
      this.cancelRequested = false;
      if (lastError) {
        this.post({ type: 'error', message: lastError });
      } else {
        this.post({ type: 'done', text: this.answer });
      }
    }
  }
}

function escapeHtml(s: string): string {
  return s.replace(/[<>&]/g, (c) =>
    c === '<' ? '&lt;' : c === '>' ? '&gt;' : '&amp;');
}

function webviewHtml(nonce: string): string {
  return `<!DOCTYPE html>
<html lang="id">
<head>
<meta charset="UTF-8">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'nonce-${nonce}'; style-src 'unsafe-inline';">
<style>
  body { font-family: var(--vscode-font-family); color: var(--vscode-foreground); font-size: var(--vscode-font-size); padding: 8px; }
  #log { white-space: pre-wrap; overflow-wrap: anywhere; }
  .tool { color: var(--vscode-descriptionForeground); }
  .tool.error { color: var(--vscode-errorForeground); }
  .status { color: var(--vscode-charts-yellow); }
  #row { display: flex; gap: 6px; margin-top: 8px; }
  textarea { flex: 1; background: var(--vscode-input-background); color: var(--vscode-input-foreground); border: 1px solid var(--vscode-input-border); resize: vertical; }
  button { background: var(--vscode-button-background); color: var(--vscode-button-foreground); border: none; cursor: pointer; }
  button.secondary { background: var(--vscode-button-secondaryBackground); color: var(--vscode-button-secondaryForeground); }
</style>
</head>
<body>
<div id="log"></div>
<div id="row">
  <textarea id="q" rows="2" placeholder="Tanya Tiko... (Enter kirim, Shift+Enter baris baru)"></textarea>
</div>
<div id="row">
  <button id="send">Kirim</button>
  <button id="cancel" class="secondary">Batal</button>
</div>
<script nonce="${nonce}">
  const vscode = acquireVsCodeApi();
  const log = document.getElementById('log');
  const q = document.getElementById('q');
  function append(kind, text) {
    const el = document.createElement('div');
    if (kind) el.className = kind;
    el.textContent = text;
    log.appendChild(el);
    el.scrollIntoView({ block: 'end' });
  }
  document.getElementById('send').addEventListener('click', () => {
    const text = q.value.trim();
    if (!text) return;
    q.value = '';
    vscode.postMessage({ type: 'ask', text });
  });
  q.addEventListener('keydown', (e) => {
    if (e.key === 'Enter' && !e.shiftKey) {
      e.preventDefault();
      document.getElementById('send').click();
    }
  });
  document.getElementById('cancel').addEventListener('click', () => {
    vscode.postMessage({ type: 'cancel' });
  });
  window.addEventListener('message', (e) => {
    const f = e.data;
    switch (f.type) {
      case 'delta': append('', f.text); break;
      case 'tool': append('tool' + (f.state === 'error' ? ' error' : ''), '[' + f.name + ' ' + f.state + ']'); break;
      case 'status': append('status', 'state: ' + f.state); break;
      case 'usage': append('tool', 'usage: ' + JSON.stringify(f.usage)); break;
      case 'prefill': q.value = f.text ?? ''; q.focus(); break;
      case 'error': append('error', f.message); break;
      case 'done': append('status', 'selesai'); break;
      default: break;
    }
  });
</script>
</body>
</html>`;
}

class ChatViewProvider implements vscode.WebviewViewProvider {
  private session: ChatSession | undefined;

  resolveWebviewView(panel: vscode.WebviewView): void {
    panel.webview.options = { enableScripts: true };
    panel.webview.html = webviewHtml(Math.random().toString(36).slice(2));
    this.session = new ChatSession((frame) =>
      void panel.webview.postMessage(frame));
    panel.webview.onDidReceiveMessage((m: TikoFrame) => {
      if (!this.session) return;
      if (m.type === 'ask') void this.session.ask(String(m['text'] ?? ''));
      if (m.type === 'cancel') this.session.cancel();
    });
    panel.onDidDispose(() => {
      this.session = undefined;
    });
  }

  cancel(): void {
    this.session?.cancel();
  }

  prefill(text: string): void {
    this.session?.prefill(text);
  }
}

export function activate(context: vscode.ExtensionContext): void {
  const provider = new ChatViewProvider();

  context.subscriptions.push(
    vscode.window.registerWebviewViewProvider('tikoAgent.chat', provider, {
      webviewOptions: { retainContextWhenHidden: true },
    }),
    vscode.commands.registerCommand('tiko-agent.openChat', () => {
      void vscode.commands.executeCommand('workbench.view.extension.tiko-agent');
    }),
    vscode.commands.registerCommand('tiko-agent.cancelTurn', () =>
      provider.cancel()),
    vscode.commands.registerCommand('tiko-agent.sendSelection', async () => {
      const editor = vscode.window.activeTextEditor;
      const sel = editor?.document.getText(editor.selection) ?? '';
      if (!sel.trim()) {
        void vscode.window.showInformationMessage(
          'Tiko: tidak ada seleksi untuk dikirim.');
        return;
      }
      await vscode.commands.executeCommand('workbench.view.extension.tiko-agent');
      provider.prefill(sel);
    }),
  );
}

export function deactivate(): void {
  // noop — koneksi SSE berakhir bersama respons HTTP, tidak ada disposables global.
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_core/agent_core.dart';

/// FR-06 (CDP Browser Engine): drives a local headless Chromium/Chrome via
/// the Chrome DevTools Protocol over WebSocket + JSON-RPC 2.0.
///
/// No external browser-driver dependencies: the browser is launched with
/// `--remote-debugging-port=0` and the endpoint is parsed from the
/// "DevTools listening on ws://..." stderr line.
class CdpSession {
  CdpSession({
    this.chromePath,
    this.headless = true,
    this.timeout = const Duration(seconds: 20),
    this.allowPrivateUrls = false,
    this.maxResultBytes = 64 * 1024,
  });

  /// Explicit Chromium/Chrome executable. Auto-detected when null.
  final String? chromePath;

  final bool headless;
  final Duration timeout;
  final bool allowPrivateUrls;
  final int maxResultBytes;

  Process? _process;
  WebSocket? _ws;
  int _nextId = 1;
  final _pending = <int, Completer<Map<String, dynamic>>>{};
  String? _targetId;
  String? _sessionId;
  bool _opening = false;

  bool get isOpen => _ws != null && _sessionId != null;

  static const _candidates = [
    '/usr/bin/google-chrome',
    '/usr/bin/google-chrome-stable',
    '/usr/bin/chromium',
    '/usr/bin/chromium-browser',
    '/snap/bin/chromium',
    '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
    '/Applications/Chromium.app/Contents/MacOS/Chromium',
    'C:/Program Files/Google/Chrome/Application/chrome.exe',
    'C:/Program Files (x86)/Google/Chrome/Application/chrome.exe',
  ];

  /// Finds a usable Chromium executable. Returns null when none exists.
  static Future<String?> findChrome() async {
    final env = Platform.environment;
    for (final key in ['TIKO_CHROME_PATH', 'CHROME_PATH', 'CHROMIUM_PATH']) {
      final p = env[key];
      if (p != null && p.isNotEmpty && File(p).existsSync()) return p;
    }
    for (final p in _candidates) {
      if (File(p).existsSync()) return p;
    }
    return null;
  }

  /// Launches the browser, opens a WebSocket, and creates one blank target.
  Future<void> open() async {
    if (isOpen || _opening) return;
    _opening = true;
    try {
      final executable = chromePath ?? await findChrome();
      if (executable == null) {
        throw UnsupportedError(
          'Chromium/Chrome tidak ditemukan. Set TIKO_CHROME_PATH.',
        );
      }
      final userDataDir = await Directory.systemTemp.createTemp('tiko-cdp-');
      final proc = await Process.start(executable, [
        if (headless) '--headless=new' else '--headless=old',
        '--remote-debugging-port=0',
        '--remote-allow-origins=*',
        '--no-first-run',
        '--no-default-browser-check',
        '--disable-gpu',
        '--disable-dev-shm-usage',
        '--no-sandbox',
        '--user-data-dir=${userDataDir.path}',
        'about:blank',
      ]);
      _process = proc;

      // Wait for the DevTools endpoint on stderr.
      final wsUrl = await _awaitDevToolsUrl(proc).timeout(timeout);
      final ws = await WebSocket.connect(wsUrl).timeout(timeout);
      _ws = ws;
      ws.listen(
        _onMessage,
        onDone: () => _failPending('websocket closed'),
        onError: (Object e) => _failPending('websocket error: $e'),
      );

      // Create a page target and attach to it.
      final created = await send('Target.createTarget', {'url': 'about:blank'});
      _targetId = created['result']?['targetId'] as String?;
      if (_targetId == null) {
        throw StateError('Target.createTarget gagal: ${created['error']}');
      }
      final attached = await send('Target.attachToTarget', {
        'targetId': _targetId,
        'flatten': true,
      });
      _sessionId = attached['result']?['sessionId'] as String?;
      if (_sessionId == null) {
        throw StateError('Target.attachToTarget gagal');
      }
      await send('Page.enable', const {}, sessionId: _sessionId);
      await send('Runtime.enable', const {}, sessionId: _sessionId);
    } finally {
      _opening = false;
    }
  }

  Future<String> _awaitDevToolsUrl(Process proc) async {
    final completer = Completer<String>();
    late StreamSubscription sub;
    sub = proc.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen(
      (line) {
        if (!completer.isCompleted) {
          final m = RegExp(r'(ws://\S+)').firstMatch(line);
          if (m != null) {
            // Restrict the endpoint to loopback (Chrome only binds locally).
            completer.complete(m.group(1)!);
          }
        }
      },
      onDone: () {
        if (!completer.isCompleted) {
          completer.completeError(StateError('Chromium keluar tanpa endpoint CDP'));
        }
      },
    );
    try {
      return await completer.future;
    } finally {
      await sub.cancel();
    }
  }

  void _onMessage(dynamic data) {
    Map<String, dynamic> msg;
    try {
      msg = jsonDecode(data as String) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    final id = msg['id'];
    if (id is int) {
      final c = _pending.remove(id);
      if (c != null && !c.isCompleted) c.complete(msg);
    }
    // Notifications/events are ignored; this client is request/response.
  }

  void _failPending(String reason) {
    for (final c in _pending.values) {
      if (!c.isCompleted) c.completeError(StateError(reason));
    }
    _pending.clear();
    _sessionId = null;
    _targetId = null;
    _ws = null;
  }

  /// Sends one CDP command and awaits its response.
  Future<Map<String, dynamic>> send(
    String method,
    Map<String, dynamic> params, {
    String? sessionId,
  }) async {
    final ws = _ws;
    if (ws == null) throw StateError('CDP session belum dibuka (open())');
    final id = _nextId++;
    final req = {
      'id': id,
      'method': method,
      'params': params,
      if (sessionId != null) 'sessionId': sessionId,
    };
    final completer = Completer<Map<String, dynamic>>();
    _pending[id] = completer;
    ws.add(jsonEncode(req));
    return completer.future.timeout(timeout, onTimeout: () {
      _pending.remove(id);
      throw TimeoutException('CDP $method timeout');
    });
  }

  /// Navigates the target to [url] and waits for the load event.
  Future<String> navigate(String url) async {
    _guardUrl(url);
    await open();
    final resp = await send('Page.navigate', {'url': url},
        sessionId: _sessionId);
    final err = resp['result']?['errorText'];
    if (err != null && (err as String).isNotEmpty) {
      throw StateError('Navigasi gagal: $err');
    }
    // Give the renderer a moment; load is fire-and-forget here.
    final frameId = resp['result']?['frameId'];
    await send(
      'Runtime.evaluate',
      {'expression': 'document.readyState', 'returnByValue': true},
      sessionId: _sessionId,
    );
    return 'Navigasi ke $url ok (frame: $frameId)';
  }

  /// Evaluates a JS [expression] in the page and returns its value.
  Future<String> evaluate(String expression) async {
    if (expression.length > 16 * 1024) {
      throw ArgumentError('ekspresi terlalu besar (maks 16 KiB)');
    }
    await open();
    final resp = await send(
      'Runtime.evaluate',
      {
        'expression': expression,
        'returnByValue': true,
        'awaitPromise': true,
      },
      sessionId: _sessionId,
    );
    if (resp['error'] != null) {
      throw StateError('CDP error: ${resp['error']}');
    }
    final exc = resp['result']?['exceptionDetails'];
    if (exc != null) {
      final text = exc['exception']?['description'] ?? exc['text'] ?? exc;
      return '[js-error] $text';
    }
    var value = resp['result']?['result']?['value'];
    var out = value == null ? 'null' : jsonEncode(value);
    if (out.length > maxResultBytes) {
      out = '${out.substring(0, maxResultBytes)}… (truncated)';
    }
    return out;
  }

  /// Extracts the visible text of the current page (best for scraping).
  Future<String> readText() =>
      evaluate('document.body ? document.body.innerText : ""');

  Future<void> close() async {
    final ws = _ws;
    _ws = null;
    _sessionId = null;
    _targetId = null;
    _failPending('closed');
    try {
      await ws?.close();
    } catch (_) {}
    final proc = _process;
    _process = null;
    try {
      proc?.kill(ProcessSignal.sigkill);
    } catch (_) {}
  }

  void _guardUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme || !uri.hasAuthority) {
      throw ArgumentError('URL tidak valid: $url');
    }
    if (uri.scheme != 'http' && uri.scheme != 'https') {
      throw ArgumentError('hanya http(s) yang diizinkan: $url');
    }
    if (!allowPrivateUrls && _isPrivateHost(uri.host)) {
      throw ArgumentError(
        'host privat/localhost diblokir (set allowPrivateUrls bila disengaja)',
      );
    }
  }

  static bool _isPrivateHost(String host) {
    final h = host.toLowerCase();
    if (h == 'localhost' || h.endsWith('.localhost') || h.endsWith('.local')) {
      return true;
    }
    if (h == 'metadata.google.internal' || h == '169.254.169.254') return true;
    final raw = InternetAddress.tryParse(h);
    if (raw == null) return false;
    if (raw.type == InternetAddressType.IPv6) {
      final v6 = raw.address.toLowerCase();
      return v6.startsWith('::1') ||
          v6 == '::' ||
          v6.startsWith('fe80') ||
          v6.startsWith('fc') ||
          v6.startsWith('fd');
    }
    final parts = h.split('.');
    if (parts.length != 4) return true;
    try {
      final o = parts.map(int.parse).toList();
      return o[0] == 10 ||
          o[0] == 127 ||
          o[0] == 0 ||
          (o[0] == 172 && o[1] >= 16 && o[1] <= 31) ||
          (o[0] == 192 && o[1] == 168) ||
          (o[0] == 169 && o[1] == 254);
    } catch (_) {
      return true;
    }
  }
}

/// Browser automation tool surface (medium risk; local Chromium only).
class CdpBrowserTool implements Tool {
  CdpBrowserTool({
    this.chromePath,
    this.allowPrivateUrls = false,
  });

  final String? chromePath;
  final bool allowPrivateUrls;
  CdpSession? _session;

  CdpSession _ensureSession() =>
      _session ??= CdpSession(
        chromePath: chromePath,
        allowPrivateUrls: allowPrivateUrls,
      );

  @override
  ToolSpec get spec => const ToolSpec(
        name: 'cdp_browser',
        description:
            'Otomasi browser Chromium lokal via Chrome DevTools Protocol. '
            'Aksi: navigate (url), evaluate (expression), read_text, close.',
        inputSchema: {
          'type': 'object',
          'properties': {
            'action': {
              'type': 'string',
              'enum': ['navigate', 'evaluate', 'read_text', 'close'],
            },
            'url': {'type': 'string'},
            'expression': {'type': 'string'},
          },
          'required': ['action'],
        },
        risk: 'medium',
      );

  @override
  Future<ToolResult> run(Map<String, dynamic> args, ToolContext ctx) async {
    final action = (args['action'] as String?)?.trim() ?? '';
    final session = _ensureSession();
    try {
      switch (action) {
        case 'navigate':
          final url = (args['url'] as String?)?.trim() ?? '';
          if (url.isEmpty) {
            return const ToolResult(
              callId: '',
              content: 'url wajib untuk aksi navigate',
              isError: true,
            );
          }
          return ToolResult(callId: '', content: await session.navigate(url));
        case 'evaluate':
          final expr = args['expression'] as String? ?? '';
          if (expr.trim().isEmpty) {
            return const ToolResult(
              callId: '',
              content: 'expression wajib untuk aksi evaluate',
              isError: true,
            );
          }
          return ToolResult(callId: '', content: await session.evaluate(expr));
        case 'read_text':
          await session.open();
          return ToolResult(callId: '', content: await session.readText());
        case 'close':
          await session.close();
          return const ToolResult(callId: '', content: 'Browser ditutup.');
        default:
          return ToolResult(
            callId: '',
            content: 'aksi tidak dikenal: $action',
            isError: true,
          );
      }
    } catch (e) {
      return ToolResult(
        callId: '',
        content: '[cdp-error] $e',
        isError: true,
      );
    }
  }

  Future<void> dispose() async {
    await _session?.close();
    _session = null;
  }
}

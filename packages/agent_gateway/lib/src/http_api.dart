import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:agent_core/agent_core.dart';
import 'package:path/path.dart' as p;

import 'webhook_endpoint.dart';
import 'skill_api.dart';

typedef MessageHandler = Future<String> Function(InboundMessage message);

/// HTTP + WebSocket API + static web UI for beginners.
class HttpApiServer {
  HttpApiServer({
    required this.onMessage,
    required this.authToken,
    this.host = '127.0.0.1',
    this.port = 8787,
    this.statusProvider,
    this.listMemories,
    this.deleteMemory,
    this.webRoot,
    this.listSessions,
    this.sessionMessages,
    this.deleteSession,
    this.renameSession,
    this.doctorProvider,
    this.capabilitiesProvider,
    this.eventsProvider,
    this.listApprovals,
    this.decideApproval,
    this.eventStream,
    this.onShutdown,
    this.webhookEndpoint,
    this.skillApi,
    this.tasksProvider,
    this.logsProvider,
    this.logContentProvider,
  });

  final MessageHandler onMessage;
  final String authToken;
  final String host;
  final int port;
  final Map<String, Object?> Function()? statusProvider;
  final Future<List<Map<String, dynamic>>> Function()? listMemories;
  final Future<bool> Function(String id)? deleteMemory;
  final String? webRoot;
  final Future<List<Map<String, dynamic>>> Function()? listSessions;

  /// Transcript of one session, oldest first. [offset] skips that many most
  /// recent messages so clients can page backwards (load-earlier).
  final Future<List<Map<String, dynamic>>> Function(
    String sessionId, {
    required int limit,
    required int offset,
  })? sessionMessages;
  final Future<bool> Function(String sessionId)? deleteSession;
  final Future<bool> Function(String sessionId, String title)? renameSession;
  final Future<List<Map<String, dynamic>>> Function()? doctorProvider;
  final Map<String, Object?> Function()? capabilitiesProvider;
  final List<Map<String, dynamic>> Function()? eventsProvider;
  final Future<List<Map<String, dynamic>>> Function()? listApprovals;
  final Future<bool> Function(String id, bool approve)? decideApproval;
  final Stream<Map<String, dynamic>>? eventStream;
  final Future<void> Function()? onShutdown;

  /// Inbound platform webhooks (WhatsApp/Slack) mounted on this server.
  final WebhookEndpoint? webhookEndpoint;

  static final Random _rng = Random.secure();

  /// Skill management callbacks (P1-03).
  final SkillApi? skillApi;

  /// Agent manager callbacks (P2-05): kanban tasks, log files, log content.
  final Future<List<Map<String, dynamic>>> Function()? tasksProvider;
  final Future<List<Map<String, dynamic>>> Function()? logsProvider;
  final Future<Map<String, dynamic>?> Function(String name)? logContentProvider;

  HttpServer? _server;
  StreamSubscription<Map<String, dynamic>>? _eventSubscription;
  int get boundPort => _server?.port ?? port;
  final _wsClients = <WebSocket>{};

  /// Bounded idempotency cache for POST /v1/messages.
  static const _idempotencyLimit = 256;
  final _idempotencyCache = <String, Future<Map<String, dynamic>>>{};


  Future<void> start() async {
    _server = await HttpServer.bind(host, port);
    _server!.listen(_handle);
    _eventSubscription = eventStream?.listen((event) {
      // Flutter chat uses the same persisted approval ID as the admin page.
      if (event['type'] == 'approval.pending') {
        final tool = event['tool'] ?? 'tool';
        broadcast({
          'type': 'confirm',
          'id': event['id'],
          'prompt': 'Izinkan $tool? ${event['args'] ?? ''}',
          'approval': event,
        });
      }
      broadcast({'type': 'event', 'event': event});
    });
  }

  Future<void> stop() async {
    await _eventSubscription?.cancel();
    for (final ws in _wsClients.toList()) {
      await ws.close();
    }
    await _server?.close(force: true);
  }

  bool _auth(HttpRequest req) {
    final h = req.headers.value('authorization') ?? '';
    if (h.startsWith('Bearer ')) {
      return _constantTimeEquals(h.substring(7), authToken);
    }
    return false;
  }

  /// Constant-time token comparison (B-08).
  bool _constantTimeEquals(String a, String b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < b.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }

  /// Short-lived one-time tickets for WebSocket auth (B-08): browsers cannot
  /// set headers on WebSocket, so the UI exchanges its Bearer token for a
  /// 30-second single-use ticket via POST /v1/auth/ticket.
  static const _ticketTtl = Duration(seconds: 30);
  final _tickets = <String, DateTime>{};

  String _issueTicket() {
    final ticket = base64UrlEncode(
      List<int>.generate(32, (_) => _rng.nextInt(256)),
    );
    _tickets[ticket] = DateTime.now().add(_ticketTtl);
    while (_tickets.length > 256) {
      _tickets.remove(_tickets.keys.first);
    }
    return ticket;
  }

  bool _consumeTicket(String ticket) {
    final exp = _tickets.remove(ticket);
    if (exp == null) return false;
    return DateTime.now().isBefore(exp);
  }

  void _pruneTickets() {
    final now = DateTime.now();
    _tickets.removeWhere((_, exp) => now.isAfter(exp));
  }

  /// Reject requests whose Host header does not match the local bind
  /// (B-08: DNS-rebinding surface).
  bool _hostAllowed(HttpRequest req) {
    final host = (req.headers.value('host') ?? '').toLowerCase();
    if (host.isEmpty) return false;
    final hostname = host.contains(':') && !host.startsWith('[')
        ? host.substring(0, host.lastIndexOf(':'))
        : host;
    const loopback = {'127.0.0.1', 'localhost', '::1', '[::1]'};
    if (loopback.contains(hostname)) return true;
    return hostname == this.host.toLowerCase();
  }

  /// Executes [run] once per [key]; duplicate requests replay the stored
  /// response instead of re-running side effects. Failed runs are evicted
  /// so a retry gets a fresh chance.
  Future<Map<String, dynamic>> _runIdempotent(
    String key,
    Future<Map<String, dynamic>> Function() run,
  ) {
    final inFlight = _idempotencyCache[key];
    if (inFlight != null) return inFlight;
    final started = run();
    _idempotencyCache[key] = started;
    while (_idempotencyCache.length > _idempotencyLimit) {
      _idempotencyCache.remove(_idempotencyCache.keys.first);
    }
    unawaited(started.catchError((Object _) {
      _idempotencyCache.remove(key);
      return <String, dynamic>{};
    }));
    return started;
  }

  Future<void> _handle(HttpRequest req) async {
    if (!_hostAllowed(req)) {
      req.response.statusCode = 421;
      await req.response.close();
      return;
    }
    req.response.headers.set(
      'Access-Control-Allow-Headers',
      'Authorization, Content-Type, Idempotency-Key',
    );
    if (req.method == 'OPTIONS') {
      req.response.statusCode = 204;
      await req.response.close();
      return;
    }

    final path = req.uri.path;

    if (path == '/v1/auth/ticket' && req.method == 'POST') {
      if (!_auth(req)) {
        req.response.statusCode = 401;
        _json(req, {'error': 'unauthorized'});
        return;
      }
      _pruneTickets();
      _json(req, {'ticket': _issueTicket(), 'ttl_seconds': _ticketTtl.inSeconds});
      return;
    }

    // Static UI (no auth for assets — local bind only)
    if (req.method == 'GET' && _isStatic(path)) {
      await _serveStatic(req, path);
      return;
    }

    // Inbound platform webhooks authenticate with HMAC signatures, not
    // with the local bearer token, so they are routed before _auth.
    if (path == '/webhooks/whatsapp' || path == '/webhooks/slack') {
      final endpoint = webhookEndpoint;
      if (endpoint == null) {
        req.response.statusCode = 403;
        _json(req, {'error': 'webhook endpoint not configured'});
      } else {
        await endpoint.handle(req, path);
      }
      return;
    }

    if (path == '/v1/stream' && WebSocketTransformer.isUpgradeRequest(req)) {
      final ticket = req.uri.queryParameters['ticket'];
      final authorized = (ticket != null && _consumeTicket(ticket)) ||
          _auth(req);
      if (!authorized) {
        req.response.statusCode = 401;
        await req.response.close();
        return;
      }
      final ws = await WebSocketTransformer.upgrade(req);
      _wsClients.add(ws);
      ws.listen(
        (data) async {
          try {
            final json = jsonDecode(data as String) as Map<String, dynamic>;
            if (json['type'] == 'confirm_response') {
              final id = json['id'] as String? ?? '';
              final allow = json['allow'] == true;
              final ok = id.isNotEmpty &&
                  await (decideApproval?.call(id, allow) ?? Future.value(false));
              ws.add(jsonEncode({'type': 'confirm_result', 'id': id, 'ok': ok}));
              return;
            }
            final text = json['text'] as String? ?? '';
            final sessionKey = json['session_key'] as String? ?? 'ws:default';
            final userKey = json['user_key'] as String? ?? 'ws';
            if (text.isEmpty) return;
            ws.add(jsonEncode({'type': 'typing'}));
            final answer = await onMessage(
              InboundMessage(
                channel: 'http',
                userKey: userKey,
                sessionKey: sessionKey,
                text: text,
              ),
            );
            ws.add(jsonEncode({'type': 'text', 'text': answer}));
            ws.add(jsonEncode({'type': 'done'}));
            await ws.close();
          } catch (e) {
            ws.add(jsonEncode({'type': 'error', 'message': e.toString()}));
            await ws.close(WebSocketStatus.internalServerError, 'request failed');
          }
        },
        onDone: () => _wsClients.remove(ws),
        onError: (_) => _wsClients.remove(ws),
      );
      return;
    }

    if (!_auth(req) && path != '/health') {
      req.response.statusCode = 401;
      req.response.write(jsonEncode({'error': 'unauthorized'}));
      await req.response.close();
      return;
    }

    try {
      if (path == '/health') {
        _json(req, {'ok': true});
      } else if (path == '/v1/status') {
        _json(req, statusProvider?.call() ?? {'ok': true});
      } else if (path == '/v1/sessions' && req.method == 'GET') {
        final sessions = await (listSessions?.call() ?? Future.value(<Map<String, dynamic>>[]));
        _json(req, {'sessions': sessions});
      } else if (path.startsWith('/v1/sessions/') &&
          path.endsWith('/messages') &&
          req.method == 'GET') {
        final id = Uri.decodeComponent(path
            .substring('/v1/sessions/'.length, path.length - '/messages'.length));
        if (id.isEmpty || id.contains('/') || id.contains('\\') || id.contains('..')) {
          req.response.statusCode = 400;
          _json(req, {'error': 'invalid session id'});
          return;
        }
        final api = sessionMessages;
        if (api == null) {
          req.response.statusCode = 501;
          _json(req, {'error': 'session history not configured'});
          return;
        }
        final q = req.uri.queryParameters;
        final limit =
            ((int.tryParse(q['limit'] ?? '') ?? 50).clamp(1, 200)).toInt();
        final offset =
            ((int.tryParse(q['offset'] ?? '') ?? 0).clamp(0, 200)).toInt();
        final messages = await api(id, limit: limit, offset: offset);
        _json(req, {
          'session_id': id,
          'messages': messages,
          'limit': limit,
          'offset': offset,
        });
      } else if (path.startsWith('/v1/sessions/') && req.method == 'DELETE') {
        final id = Uri.decodeComponent(path.substring('/v1/sessions/'.length));
        if (id.isEmpty || id.contains('/') || id.contains('\\') || id.contains('..')) {
          req.response.statusCode = 400;
          _json(req, {'error': 'invalid session id'});
        } else {
          final ok = await (deleteSession?.call(id) ?? Future.value(false));
          _json(req, {'deleted': ok});
        }
      } else if (path.startsWith('/v1/sessions/') && req.method == 'PATCH') {
        final id = Uri.decodeComponent(path.substring('/v1/sessions/'.length));
        if (id.isEmpty || id.contains('/') || id.contains('\\') || id.contains('..')) {
          req.response.statusCode = 400;
          _json(req, {'error': 'invalid session id'});
          return;
        }
        final body =
            jsonDecode(await utf8.decoder.bind(req).join()) as Map<String, dynamic>;
        final title = body['title'] as String? ?? '';
        final ok = await (renameSession?.call(id, title) ?? Future.value(false));
        if (!ok) {
          req.response.statusCode = 404;
          _json(req, {'ok': false, 'error': 'session not found or rename unsupported'});
        } else {
          _json(req, {'ok': true, 'id': id, 'title': title});
        }
      } else if (path == '/v1/doctor' && req.method == 'GET') {
        final d = await (doctorProvider?.call() ?? Future.value(<Map<String, dynamic>>[]));
        _json(req, {'checks': d});
      } else if (path == '/v1/capabilities' && req.method == 'GET') {
        _json(req, capabilitiesProvider?.call() ?? {'ok': true});
      } else if (path == '/v1/events' && req.method == 'GET') {
        _json(req, {'events': eventsProvider?.call() ?? []});
      } else if (path == '/v1/tasks' && req.method == 'GET') {
        final tasks =
            await (tasksProvider?.call() ?? Future.value(<Map<String, dynamic>>[]));
        _json(req, {'tasks': tasks});
      } else if (path == '/v1/logs' && req.method == 'GET') {
        final logs =
            await (logsProvider?.call() ?? Future.value(<Map<String, dynamic>>[]));
        _json(req, {'logs': logs});
      } else if (path.startsWith('/v1/logs/') && req.method == 'GET') {
        final name = Uri.decodeComponent(path.substring('/v1/logs/'.length));
        if (name.isEmpty || name.contains('/') || name.contains('\\') || name.contains('..')) {
          req.response.statusCode = 400;
          _json(req, {'error': 'invalid log name'});
        } else {
          final content = await (logContentProvider?.call(name) ??
              Future<Map<String, dynamic>?>.value(null));
          if (content == null) {
            req.response.statusCode = 404;
            _json(req, {'error': 'log not found'});
          } else {
            _json(req, content);
          }
        }
      } else if (path == '/v1/approvals' && req.method == 'GET') {
        final list = await (listApprovals?.call() ?? Future.value(<Map<String, dynamic>>[]));
        _json(req, {'approvals': list});
      } else if (path.startsWith('/v1/approvals/') && req.method == 'POST') {
        final id = path.substring('/v1/approvals/'.length).split('/').first;
        final body = jsonDecode(await utf8.decoder.bind(req).join()) as Map<String, dynamic>;
        final allow = body['approve'] == true || path.endsWith('/approve');
        final ok = await (decideApproval?.call(id, allow) ?? Future.value(false));
        _json(req, {'ok': ok, 'id': id, 'approve': allow});
      } else if (path == '/v1/messages' && req.method == 'POST') {
        final body =
            jsonDecode(await utf8.decoder.bind(req).join())
                as Map<String, dynamic>;
        final text = body['text'] as String? ?? '';
        final sessionKey = body['session_key'] as String? ?? 'http:default';
        final userKey = body['user_key'] as String? ?? 'http';
        final idempotencyKey = req.headers.value('idempotency-key') ?? '';
        if (idempotencyKey.trim().isEmpty) {
          final answer = await onMessage(
            InboundMessage(
              channel: 'http',
              userKey: userKey,
              sessionKey: sessionKey,
              text: text,
            ),
          );
          _json(req, {'text': answer});
        } else {
          final replayed = _idempotencyCache.containsKey(idempotencyKey);
          final result = await _runIdempotent(idempotencyKey, () async {
            final answer = await onMessage(
              InboundMessage(
                channel: 'http',
                userKey: userKey,
                sessionKey: sessionKey,
                text: text,
              ),
            );
            return {'text': answer};
          });
          if (replayed) {
            req.response.headers.set('Idempotency-Replayed', 'true');
          }
          final payload = Map<String, dynamic>.from(result);
          if (replayed) {
            payload['idempotent_replay'] = true;
          }
          _json(req, payload);
        }
      } else if (path == '/v1/shutdown' && req.method == 'POST') {
        if (onShutdown == null) {
          req.response.statusCode = 409;
          _json(req, {'ok': false, 'error': 'shutdown is unavailable'});
        } else {
          // Flush the acknowledgement before signaling agentd to close its
          // HttpServer; otherwise the response can be cut off during teardown.
          req.response.headers.contentType = ContentType.json;
          req.response.write(jsonEncode({'ok': true}));
          await req.response.close();
          await onShutdown!.call();
        }
      } else if (path == '/v1/confirm' && req.method == 'POST') {
        final body =
            jsonDecode(await utf8.decoder.bind(req).join())
                as Map<String, dynamic>;
        final id = body['id'] as String? ?? '';
        final allow = body['allow'] == true;
        final ok = id.isNotEmpty &&
            await (decideApproval?.call(id, allow) ?? Future.value(false));
        _json(req, {'ok': ok, 'id': id, 'approve': allow});
      } else if (path == '/v1/memories' && req.method == 'GET') {
        final mems =
            await (listMemories?.call() ??
                Future.value(<Map<String, dynamic>>[]));
        _json(req, {'memories': mems});
      } else if (path.startsWith('/v1/memories/') && req.method == 'DELETE') {
        final id = path.substring('/v1/memories/'.length);
        final ok = await (deleteMemory?.call(id) ?? Future.value(false));
        _json(req, {'deleted': ok});
      // Skill management endpoints (P1-03)
      } else if (path == '/v1/skills' && req.method == 'GET') {
        final api = skillApi;
        if (api == null) {
          _json(req, {'error': 'skill API not configured'});
        } else {
          final result = await api.listSkills(req);
          _json(req, result);
        }
      } else if (path.startsWith('/v1/skills/') && req.method == 'GET') {
        final api = skillApi;
        if (api == null) {
          _json(req, {'error': 'skill API not configured'});
        } else {
          final slug = path.substring('/v1/skills/'.length).split('/').first;
          if (path == '/v1/skills/$slug') {
            final result = await api.getSkill(req, slug);
            _json(req, result);
          } else if (path == '/v1/skills/$slug/history') {
            final result = await api.getSkillHistory(req, slug);
            _json(req, result);
          } else if (path == '/v1/skills/$slug/metrics') {
            final result = await api.getSkillMetrics(req, slug);
            _json(req, result);
          } else {
            req.response.statusCode = 404;
            _json(req, {'error': 'not found'});
          }
        }
      } else if (path.startsWith('/v1/skills/') && req.method == 'POST') {
        final api = skillApi;
        if (api == null) {
          _json(req, {'error': 'skill API not configured'});
        } else {
          final slug = path.substring('/v1/skills/'.length).split('/').first;
          final rest = path.substring('/v1/skills/$slug'.length);
          if (rest == '/feedback') {
            final result = await api.recordFeedback(req, slug);
            _json(req, result);
          } else if (rest == '/evaluate') {
            final result = await api.evaluateSkill(req, slug);
            _json(req, result);
          } else if (rest == '/approve') {
            final result = await api.approveSkill(req, slug);
            _json(req, result);
          } else if (rest == '/rollback') {
            final result = await api.rollbackSkill(req, slug);
            _json(req, result);
          } else {
            req.response.statusCode = 404;
            _json(req, {'error': 'not found'});
          }
        }
      } else if (path.startsWith('/v1/sessions/') &&
          req.method == 'POST' &&
          path.endsWith('/feedback')) {
        final api = skillApi;
        if (api == null) {
          _json(req, {'error': 'skill API not configured'});
        } else {
          final sessionId = path
              .substring('/v1/sessions/'.length,
                  path.length - '/feedback'.length)
              .trim();
          if (sessionId.isEmpty || sessionId.contains('/')) {
            req.response.statusCode = 400;
            _json(req, {'error': 'invalid session id'});
          } else {
            final result = await api.recordSessionFeedback(req, sessionId);
            _json(req, result);
          }
        }
      } else {
        req.response.statusCode = 404;
        _json(req, {'error': 'not found'});
      }
    } catch (e) {
      req.response.statusCode = 500;
      _json(req, {'error': e.toString()});
    }
  }

  bool _isStatic(String path) {
    return path == '/' ||
        path == '/index.html' ||
        path == '/app.js' ||
        path == '/app.css' ||
        path == '/favicon.ico';
  }

  Future<void> _serveStatic(HttpRequest req, String path) async {
    final root = webRoot;
    if (root == null) {
      req.response.statusCode = 404;
      await req.response.close();
      return;
    }
    final rel = path == '/' ? 'index.html' : path.substring(1);
    if (rel.contains('..')) {
      req.response.statusCode = 400;
      await req.response.close();
      return;
    }
    final file = File(p.join(root, rel));
    if (!await file.exists()) {
      req.response.statusCode = 404;
      await req.response.close();
      return;
    }
    if (rel.endsWith('.html')) {
      req.response.headers.contentType = ContentType(
        'text',
        'html',
        charset: 'utf-8',
      );
    } else if (rel.endsWith('.js')) {
      req.response.headers.contentType = ContentType(
        'application',
        'javascript',
        charset: 'utf-8',
      );
    } else if (rel.endsWith('.css')) {
      req.response.headers.contentType = ContentType(
        'text',
        'css',
        charset: 'utf-8',
      );
    }
    await req.response.addStream(file.openRead());
    await req.response.close();
  }

  void _json(HttpRequest req, Object data) {
    req.response.headers.contentType = ContentType.json;
    req.response.write(jsonEncode(data));
    req.response.close();
  }

  void broadcast(Map<String, dynamic> event) {
    final payload = jsonEncode(event);
    for (final ws in _wsClients) {
      ws.add(payload);
    }
  }

}

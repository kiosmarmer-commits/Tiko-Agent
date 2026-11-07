import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_core/agent_core.dart';
import 'package:path/path.dart' as p;

import 'webhook_endpoint.dart';

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
    this.doctorProvider,
    this.capabilitiesProvider,
    this.eventsProvider,
    this.listApprovals,
    this.decideApproval,
    this.eventStream,
    this.onShutdown,
    this.webhookEndpoint,
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
  final Future<List<Map<String, dynamic>>> Function()? doctorProvider;
  final Map<String, Object?> Function()? capabilitiesProvider;
  final List<Map<String, dynamic>> Function()? eventsProvider;
  final Future<List<Map<String, dynamic>>> Function()? listApprovals;
  final Future<bool> Function(String id, bool approve)? decideApproval;
  final Stream<Map<String, dynamic>>? eventStream;
  final Future<void> Function()? onShutdown;

  /// Inbound platform webhooks (WhatsApp/Slack) mounted on this server.
  final WebhookEndpoint? webhookEndpoint;

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
    if (h == 'Bearer $authToken') return true;
    final q = req.uri.queryParameters['token'];
    return q == authToken;
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
    req.response.headers.set('Access-Control-Allow-Origin', '*');
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
      if (!_auth(req)) {
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
      } else if (path == '/v1/doctor' && req.method == 'GET') {
        final d = await (doctorProvider?.call() ?? Future.value(<Map<String, dynamic>>[]));
        _json(req, {'checks': d});
      } else if (path == '/v1/capabilities' && req.method == 'GET') {
        _json(req, capabilitiesProvider?.call() ?? {'ok': true});
      } else if (path == '/v1/events' && req.method == 'GET') {
        _json(req, {'events': eventsProvider?.call() ?? []});
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

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'oauth.dart';
import 'transport.dart';
import 'stdio_client.dart' show McpToolInfo, McpToolServer;

/// MCP client over Streamable HTTP (JSON-RPC POST, optional SSE responses).
///
/// Implements the Streamable HTTP session lifecycle:
/// - captures the mcp-session-id header assigned by the server during
///   initialize and echoes it on every subsequent request;
/// - accepts single JSON, JSON batch, and text/event-stream responses;
/// - collects server notifications that arrive alongside responses;
/// - terminates the session with a best-effort DELETE on close.
class HttpMcpClient implements McpTransport, McpToolServer {
  HttpMcpClient({
    required this.baseUrl,
    this.headers = const {},
    this.httpClient,
    this.protocolVersion = '2025-11-25',
    this.maxOutputChars = 100000,
    this.maxReadRetries = 2,
    this.maxEventChars = 262144,
    this.maxObservedEvents = 100,
    this.oauth,
  }) {
    final endpoint = Uri.tryParse(baseUrl);
    if (endpoint == null ||
        !const {'http', 'https'}.contains(endpoint.scheme) ||
        endpoint.host.isEmpty ||
        endpoint.userInfo.isNotEmpty ||
        endpoint.hasFragment ||
        RegExp(r'[\x00-\x20\x7F]').hasMatch(baseUrl)) {
      throw ArgumentError.value(baseUrl, 'baseUrl', 'Expected a safe HTTP(S) MCP URL');
    }
    if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(protocolVersion)) {
      throw ArgumentError.value(protocolVersion, 'protocolVersion', 'Expected YYYY-MM-DD');
    }
    if (maxOutputChars <= 0 || maxEventChars <= 0 || maxObservedEvents <= 0) {
      throw RangeError('MCP output/event/observation limits must be positive');
    }
    if (maxReadRetries < 0 || maxReadRetries > 3) {
      throw RangeError.range(maxReadRetries, 0, 3, 'maxReadRetries');
    }
    if (headers.length > 32) {
      throw RangeError.range(headers.length, 0, 32, 'headers.length');
    }
    final reservedHeaders = {
      'content-type',
      'accept',
      'mcp-session-id',
      'mcp-protocol-version',
    };
    for (final entry in headers.entries) {
      if (!RegExp(r'^[A-Za-z0-9-]{1,64}$').hasMatch(entry.key) ||
          reservedHeaders.contains(entry.key.toLowerCase()) ||
          entry.value.length > 8192 ||
          RegExp(r'[\x00-\x1F\x7F]').hasMatch(entry.value)) {
        // Reserved headers are owned by the transport and are ignored by
        // _customHeaders; reject malformed names/values at construction.
        if (reservedHeaders.contains(entry.key.toLowerCase())) continue;
        throw ArgumentError.value(entry.key, 'headers', 'Unsafe MCP HTTP header');
      }
    }
  }

  final String baseUrl;
  final Map<String, String> headers;
  final http.Client? httpClient;
  final String protocolVersion;

  /// Optional OAuth 2.0 client-credentials token source (P2-14). When set,
  /// a `Authorization: Bearer` header is attached to every request and a 401
  /// triggers exactly one token refresh + replay.
  final McpOAuthClientCredentials? oauth;

  /// Batas total karakter keluaran tool sebelum ditolak.
  final int maxOutputChars;

  /// Bounded retries for read-only JSON-RPC methods only. Tool calls and
  /// notifications are never retried because their effects may be repeated.
  final int maxReadRetries;

  /// Maximum size of one SSE event payload before that event is discarded.
  final int maxEventChars;

  /// Maximum number of recent notifications/requests/errors retained.
  final int maxObservedEvents;

  int _nextId = 1;
  bool _started = false;
  bool _closed = false;
  bool _protocolNegotiated = false;
  bool _recovering = false;
  bool _oauthRefreshing = false;
  String? _authToken;
  int _eventStreamReconnectAttempts = 0;
  static const int _maxEventStreamReconnects = 3;
  late String _negotiatedProtocolVersion = protocolVersion;
  Future<void>? _starting;
  String? _sessionId;
  String? serverName;
  http.Client? _ownedClient;
  StreamSubscription<String>? _eventStreamSubscription;
  final _serverEventController =
      StreamController<Map<String, dynamic>>.broadcast();
  final _pendingSseData = StringBuffer();
  bool _discardingSseEvent = false;

  http.Client get _client => httpClient ?? (_ownedClient ??= http.Client());

  /// Session id yang diberikan server saat initialize, bila ada.
  String? get sessionId => _sessionId;

  /// Notifikasi dari server yang diterima sejak start.
  final List<Map<String, dynamic>> notifications = [];

  /// Server-initiated JSON-RPC requests (with an `id`) observed on GET SSE.
  /// They are exposed for diagnostics; request handling is not implemented.
  final List<Map<String, dynamic>> serverRequests = [];

  /// Errors from the optional GET event stream, independent of JSON-RPC calls.
  final List<Map<String, dynamic>> transportErrors = [];

  /// Live stream of notifications received from POST responses or GET SSE.
  Stream<Map<String, dynamic>> get serverEvents => _serverEventController.stream;

  @override
  Future<void> start() async {
    if (_closed) throw StateError('MCP HTTP client is closed');
    if (_started) return;
    final pending = _starting ??= _start();
    try {
      await pending;
    } catch (_) {
      _starting = null;
      rethrow;
    }
  }

  Future<void> _start() async {
    try {
      final init = await _send('initialize', {
        'protocolVersion': protocolVersion,
        'capabilities': {'tools': {}},
        'clientInfo': {'name': 'tiko', 'version': '0.1.0'},
      });
      final selectedVersion = init['protocolVersion'];
      if (selectedVersion != null) {
        if (selectedVersion is! String ||
            !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(selectedVersion)) {
          throw const FormatException(
            'MCP initialize returned an invalid protocolVersion',
          );
        }
        _negotiatedProtocolVersion = selectedVersion;
      }
      _protocolNegotiated = true;
      final info = init['serverInfo'];
      if (info is Map && info['name'] is String) {
        serverName = info['name'] as String;
      }
      await _sendNotification('notifications/initialized');
      _started = true;
      try {
        await _startEventStream();
      } catch (error) {
        // GET SSE is optional; a transient failure must not disable POST RPC.
        _retainObserved(transportErrors, {
          'error': error.toString(),
          'at': DateTime.now().toUtc().toIso8601String(),
        });
      }
    } catch (_) {
      _started = false;
      rethrow;
    }
  }

  /// Opens the optional server-to-client event stream defined by Streamable
  /// HTTP. A 404/405 means the server does not offer GET SSE; POST RPC remains
  /// usable. The subscription is kept alive until [close].
  Future<void> _startEventStream() async {
    final request = http.Request('GET', Uri.parse(baseUrl));
    request.headers.addAll(_sessionHeaders(accept: 'text/event-stream'));
    final response = await _client
        .send(request)
        .timeout(const Duration(seconds: 10));

    if (response.statusCode == 404 || response.statusCode == 405) {
      await _discardResponse(response.stream);
      return;
    }
    if (response.statusCode != 200) {
      final statusCode = response.statusCode;
      await _discardResponse(response.stream);
      throw StateError('MCP GET SSE HTTP $statusCode');
    }
    final contentType = response.headers['content-type'] ?? '';
    if (!contentType.toLowerCase().contains('text/event-stream')) {
      await _discardResponse(response.stream);
      return;
    }
    _eventStreamSubscription = response.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          _consumeEventStreamLine,
          onError: (Object error, StackTrace stack) {
            // The main request path remains available if a server closes or
            // breaks its optional event stream. Reconnect with backoff (P1-9).
            _retainObserved(transportErrors, {
              'error': error.toString(),
              'at': DateTime.now().toUtc().toIso8601String(),
            });
            _scheduleEventStreamReconnect('stream error: $error');
          },
          onDone: () {
            _dispatchEventStreamData();
            _scheduleEventStreamReconnect('stream closed by server');
          },
          cancelOnError: true,
        );
  }

  /// Reconnects the optional GET event stream with bounded exponential
  /// backoff (P1-9). The counter resets after every successful connection,
  /// so only consecutive failures are bounded.
  void _scheduleEventStreamReconnect(String reason) {
    if (_closed || !_started) return;
    if (_eventStreamReconnectAttempts >= _maxEventStreamReconnects) {
      _retainObserved(transportErrors, {
        'error':
            'MCP SSE reconnect limit reached ($_maxEventStreamReconnects): $reason',
        'at': DateTime.now().toUtc().toIso8601String(),
      });
      return;
    }
    final attempt = _eventStreamReconnectAttempts++;
    _retainObserved(transportErrors, {
      'error': 'MCP SSE stream down; reconnecting ($reason)',
      'at': DateTime.now().toUtc().toIso8601String(),
    });
    unawaited(() async {
      await Future<void>.delayed(
        Duration(milliseconds: 200 * (1 << (attempt > 2 ? 2 : attempt))),
      );
      if (_closed || !_started) return;
      try {
        await _startEventStream();
        _eventStreamReconnectAttempts = 0;
      } catch (error) {
        _retainObserved(transportErrors, {
          'error': 'MCP SSE reconnect failed: $error',
          'at': DateTime.now().toUtc().toIso8601String(),
        });
        _scheduleEventStreamReconnect('reconnect failed: $error');
      }
    }());
  }

  void _consumeEventStreamLine(String line) {
    if (line.isEmpty) {
      if (_discardingSseEvent) {
        _discardingSseEvent = false;
        _pendingSseData.clear();
      } else {
        _dispatchEventStreamData();
      }
      return;
    }
    if (_discardingSseEvent || line.startsWith(':') || !line.startsWith('data:')) {
      return;
    }
    var value = line.substring(5);
    if (value.startsWith(' ')) value = value.substring(1);
    final separatorLength = _pendingSseData.isNotEmpty ? 1 : 0;
    if (_pendingSseData.length + separatorLength + value.length > maxEventChars) {
      _pendingSseData.clear();
      _discardingSseEvent = true;
      _retainObserved(transportErrors, {
        'error': 'MCP SSE event exceeded $maxEventChars characters',
        'at': DateTime.now().toUtc().toIso8601String(),
      });
      return;
    }
    if (_pendingSseData.isNotEmpty) _pendingSseData.write('\n');
    _pendingSseData.write(value);
  }

  void _dispatchEventStreamData() {
    if (_pendingSseData.isEmpty) return;
    final payload = _pendingSseData.toString();
    _pendingSseData.clear();
    try {
      final decoded = jsonDecode(payload);
      if (decoded is! Map<String, dynamic>) return;
      if (decoded['id'] == null) {
        _retainObserved(notifications, decoded);
        if (!_serverEventController.isClosed) {
          _serverEventController.add(decoded);
        }
      } else {
        _retainObserved(serverRequests, decoded);
      }
    } catch (_) {
      // Ignore malformed SSE events; the POST response path remains intact.
    }
  }

  @override
  Future<Map<String, dynamic>> request(
    String method, [
    Map<String, dynamic>? params,
  ]) async {
    if (!_started) await start();
    return _send(method, params);
  }

  @override
  Future<void> notify(String method, [Map<String, dynamic>? params]) async {
    if (!_started) await start();
    await _sendNotification(method, params);
  }

  /// List tools exposed by the server. Names and schemas are untrusted
  /// config inputs; malformed entries abort loading instead of being
  /// partially used.
  @override
  Future<List<McpToolInfo>> listTools() async {
    final res = await request('tools/list');
    final raw = res['tools'];
    if (raw is! List || raw.length > 128) {
      throw const FormatException('invalid MCP tools/list response');
    }
    return raw.map((item) {
      if (item is! Map) throw const FormatException('invalid MCP tool entry');
      final name = item['name'];
      final description = item['description'];
      final schema = item['inputSchema'];
      if (name is! String ||
          !RegExp(r'^[A-Za-z0-9][A-Za-z0-9_.-]{0,95}$').hasMatch(name)) {
        throw const FormatException('invalid MCP tool name');
      }
      if (description != null && description is! String) {
        throw const FormatException('invalid MCP tool description');
      }
      if (schema != null && schema is! Map) {
        throw const FormatException('invalid MCP input schema');
      }
      final descriptionText = description as String? ?? '';
      return McpToolInfo(
        name: name,
        description: descriptionText.length > 2000
            ? descriptionText.substring(0, 2000)
            : descriptionText,
        inputSchema: schema is Map
            ? Map<String, dynamic>.from(schema)
            : const {'type': 'object', 'properties': <String, dynamic>{}},
      );
    }).toList(growable: false);
  }

  /// Call a server tool. Output is untrusted and always wrapped in an
  /// untrusted_data envelope with escaped inner delimiters.
  @override
  Future<String> callTool(String name, Map<String, dynamic> arguments) async {
    final res = await request('tools/call', {
      'name': name,
      'arguments': arguments,
    });
    final content = res['content'];
    if (content == null) return jsonEncode(res);
    if (content is! List || content.length > 128) {
      throw const FormatException('invalid MCP tool result content');
    }
    final texts = <String>[];
    var totalChars = 0;
    for (final item in content) {
      if (item is! Map) continue;
      if (item['type'] == 'text') {
        final text = item['text'];
        if (text is String) {
          totalChars += text.length;
          if (totalChars > maxOutputChars) {
            throw const FormatException('MCP output too large');
          }
          texts.add(text);
        }
      } else {
        final encoded = jsonEncode(item);
        totalChars += encoded.length;
        if (totalChars > maxOutputChars) {
          throw const FormatException('MCP output too large');
        }
        texts.add(encoded);
      }
    }
    final body = texts.join('\n');
    if (res['isError'] == true) return 'MCP error: $body';
    final safeSource =
        (serverName ?? 'server').replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '_');
    final safeBody = body
        .replaceAll('</untrusted_data', '<\\/untrusted_data')
        .replaceAll('<untrusted_data', '<\\untrusted_data');
    return '<untrusted_data source="mcp-http:$safeSource">\n$safeBody\n</untrusted_data>';
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final subscription = _eventStreamSubscription;
    _eventStreamSubscription = null;
    try {
      await subscription?.cancel();
    } catch (_) {}

    final sid = _sessionId;
    _sessionId = null;
    _started = false;
    _starting = null;
    _recovering = false;
    _oauthRefreshing = false;
    _authToken = null;
    _eventStreamReconnectAttempts = 0;
    final client = _client;
    try {
      if (sid != null) {
        await client
            .delete(
              Uri.parse(baseUrl),
              headers: {
                ..._customHeaders,
                'accept': 'application/json, text/event-stream',
                'mcp-session-id': sid,
                if (_protocolNegotiated)
                  'mcp-protocol-version': _negotiatedProtocolVersion,
              },
            )
            .timeout(const Duration(seconds: 5));
      }
    } catch (_) {
      // Terminasi session bersifat best-effort.
    } finally {
      _ownedClient?.close();
      _ownedClient = null;
      notifications.clear();
      serverRequests.clear();
      transportErrors.clear();
      _pendingSseData.clear();
      _discardingSseEvent = false;
      if (!_serverEventController.isClosed) {
        await _serverEventController.close();
      }
    }
  }

  Future<Map<String, dynamic>> _send(
    String method, [
    Map<String, dynamic>? params,
  ]) async {
    final id = _nextId++;
    final body = <String, dynamic>{
      'jsonrpc': '2.0',
      'id': id,
      'method': method,
      if (params != null) 'params': params,
    };
    final messages = await _post(
      body,
      retryable: _isReadOnlyMethod(method),
    );
    Map<String, dynamic>? match;
    for (final message in messages) {
      if (message['id'] == id) match = message;
    }
    if (match == null) {
      throw StateError('MCP HTTP response missing id $id for $method');
    }
    if (match.containsKey('error')) {
      throw StateError('MCP RPC error: ${jsonEncode(match['error'])}');
    }
    final result = match['result'];
    if (result is Map<String, dynamic>) return result;
    if (result == null) return const {};
    throw const FormatException('invalid MCP result object');
  }

  Future<void> _sendNotification(
    String method, [
    Map<String, dynamic>? params,
  ]) async {
    await _post(<String, dynamic>{
      'jsonrpc': '2.0',
      'method': method,
      if (params != null) 'params': params,
    });
  }

  Future<List<Map<String, dynamic>>> _post(
    Map<String, dynamic> body, {
    bool retryable = false,
  }) async {
    if (_closed) throw StateError('MCP HTTP client is closed');
    final encodedBody = jsonEncode(body);
    if (oauth != null) {
      _authToken = await oauth!.token();
    }
    http.Response response;
    var attempt = 0;
    while (true) {
      try {
        response = await _client
            .post(
              Uri.parse(baseUrl),
              headers: _requestHeaders(),
              body: encodedBody,
            )
            .timeout(const Duration(seconds: 30));
      } on http.ClientException {
        if (!retryable || attempt >= maxReadRetries) rethrow;
        await _waitBeforeReadRetry(attempt++);
        continue;
      } on SocketException {
        if (!retryable || attempt >= maxReadRetries) rethrow;
        await _waitBeforeReadRetry(attempt++);
        continue;
      }

      if (!_isTransientStatus(response.statusCode) ||
          !retryable ||
          attempt >= maxReadRetries) {
        break;
      }
      attempt++;
      await _waitBeforeReadRetry(attempt - 1);
    }

    final sid = response.headers['mcp-session-id'];
    if (sid != null && sid.isNotEmpty) _sessionId = sid;
    if (response.statusCode == 404 &&
        _sessionId != null &&
        !_closed &&
        !_recovering) {
      // Session expired (server restart or TTL). The request never reached
      // the tool layer, so re-initializing and replaying it once is safe,
      // including for tools/call (P1-9).
      _recovering = true;
      try {
        _retainObserved(transportErrors, {
          'error': 'MCP HTTP 404 session expired; re-initializing',
          'at': DateTime.now().toUtc().toIso8601String(),
        });
        final staleEvents = _eventStreamSubscription;
        _eventStreamSubscription = null;
        try {
          await staleEvents?.cancel();
        } catch (_) {}
        _sessionId = null;
        _protocolNegotiated = false;
        _started = false;
        _starting = null;
        await start();
        return await _post(body, retryable: retryable);
      } finally {
        _recovering = false;
      }
    }
    if (response.statusCode == 401 &&
        oauth != null &&
        !_oauthRefreshing &&
        !_closed) {
      // Access token rejected: refresh once and replay. The guard flag
      // prevents infinite 401 loops when credentials are simply wrong.
      _oauthRefreshing = true;
      try {
        oauth!.invalidate();
        _authToken = await oauth!.token();
        _retainObserved(transportErrors, {
          'error': 'MCP HTTP 401; OAuth token refreshed',
          'at': DateTime.now().toUtc().toIso8601String(),
        });
        return await _post(body, retryable: retryable);
      } finally {
        _oauthRefreshing = false;
      }
    }
    if (response.statusCode >= 400) {
      final detail = response.body.length > 1000
          ? response.body.substring(0, 1000)
          : response.body;
      throw StateError('MCP HTTP ${response.statusCode}: $detail');
    }

    final contentType = response.headers['content-type'] ?? '';
    final text = response.body.trim();
    final List<Map<String, dynamic>> messages;
    if (contentType.toLowerCase().contains('text/event-stream') ||
        text.startsWith('data:')) {
      messages = _messagesFromSse(text);
    } else if (text.isEmpty) {
      messages = const [];
    } else {
      final decoded = jsonDecode(text);
      if (decoded is Map<String, dynamic>) {
        messages = [decoded];
      } else if (decoded is List) {
        final out = <Map<String, dynamic>>[];
        for (final item in decoded) {
          if (item is! Map) {
            throw const FormatException('invalid MCP batch response');
          }
          out.add(Map<String, dynamic>.from(item));
        }
        messages = out;
      } else {
        throw const FormatException('invalid MCP HTTP response body');
      }
    }

    final withId = <Map<String, dynamic>>[];
    for (final message in messages) {
      if (message['id'] == null) {
        _retainObserved(notifications, message);
        if (!_serverEventController.isClosed) {
          _serverEventController.add(message);
        }
      } else {
        withId.add(message);
      }
    }
    return withId;
  }

  void _retainObserved(
    List<Map<String, dynamic>> target,
    Map<String, dynamic> value,
  ) {
    target.add(value);
    if (target.length > maxObservedEvents) target.removeAt(0);
  }

  static bool _isReadOnlyMethod(String method) => const {
        'ping',
        'tools/list',
        'resources/list',
        'resources/templates/list',
        'resources/read',
        'prompts/list',
        'prompts/get',
      }.contains(method);

  static bool _isTransientStatus(int statusCode) => const {
        408,
        425,
        429,
        502,
        503,
        504,
      }.contains(statusCode);

  Future<void> _waitBeforeReadRetry(int attempt) async {
    final exponent = attempt < 0 ? 0 : (attempt > 2 ? 2 : attempt);
    await Future<void>.delayed(
      Duration(milliseconds: 200 * (1 << exponent)),
    );
  }

  List<Map<String, dynamic>> _messagesFromSse(String text) {
    final out = <Map<String, dynamic>>[];
    for (final block in text.split(RegExp(r'\r?\n\r?\n'))) {
      final data = StringBuffer();
      for (final line in block.split(RegExp(r'\r?\n'))) {
        if (line.startsWith('data:')) {
          data.write(line.substring(5).trim());
          data.write('\n');
        }
      }
      final payload = data.toString().trim();
      if (payload.isEmpty) continue;
      try {
        final decoded = jsonDecode(payload);
        if (decoded is Map<String, dynamic>) out.add(decoded);
      } catch (_) {
        // Blok SSE rusak dilewati; respons dengan id cocok yang diutamakan.
      }
    }
    return out;
  }

  Map<String, String> get _customHeaders => {
        for (final entry in headers.entries)
          if (!const {
            'content-type',
            'accept',
            'mcp-session-id',
            'mcp-protocol-version',
          }.contains(entry.key.toLowerCase()))
            entry.key: entry.value,
      };

  Map<String, String> _sessionHeaders({
    required String accept,
    bool includeContentType = false,
  }) => {
        ..._customHeaders,
        if (includeContentType) 'content-type': 'application/json',
        'accept': accept,
        if (_sessionId != null) 'mcp-session-id': _sessionId!,
        if (_protocolNegotiated)
          'mcp-protocol-version': _negotiatedProtocolVersion,
        if (_authToken != null) 'authorization': 'Bearer ${_authToken!}',
      };

  Map<String, String> _requestHeaders() => _sessionHeaders(
        accept: 'application/json, text/event-stream',
        includeContentType: true,
      );

  Future<void> _discardResponse(Stream<List<int>> stream) async {
    final subscription = stream.listen((_) {});
    await subscription.cancel();
  }
}

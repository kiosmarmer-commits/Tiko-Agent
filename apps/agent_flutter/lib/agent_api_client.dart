import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

import 'data/api_error.dart';

/// HTTP/WS client for Tiko control plane API.
class AgentApiClient {
  AgentApiClient({required this.baseUrl, required this.token});

  String baseUrl;
  String token;
  final _http = http.Client();

  Map<String, String> get _headers => {
        'Authorization': 'Bearer $token',
        'Content-Type': 'application/json',
      };

  Uri _u(String path) =>
      Uri.parse('${baseUrl.replaceAll(RegExp(r'/$'), '')}$path');

  Future<bool> health() async {
    try {
      final res =
          await _http.get(_u('/health')).timeout(const Duration(seconds: 4));
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  Future<Map<String, dynamic>> status() async {
    final res = await _http.get(_u('/v1/status'), headers: _headers);
    _throwIf(res, 'status');
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> capabilities() async {
    final res = await _http.get(_u('/v1/capabilities'), headers: _headers);
    _throwIf(res, 'capabilities');
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  Future<List<Map<String, dynamic>>> doctor() async {
    final res = await _http.get(_u('/v1/doctor'), headers: _headers);
    _throwIf(res, 'doctor');
    final json = jsonDecode(res.body) as Map<String, dynamic>;
    final list = json['checks'] as List<dynamic>? ?? [];
    return list.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  Future<List<Map<String, dynamic>>> listSessions() async {
    final res = await _http.get(_u('/v1/sessions'), headers: _headers);
    _throwIf(res, 'sessions');
    final json = jsonDecode(res.body) as Map<String, dynamic>;
    final list = json['sessions'] as List<dynamic>? ?? [];
    return list.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  /// Transcript satu sesi, oldest first. [offset] melewati sebanyak itu
  /// pesan terbaru sehingga klien dapat memuat riwayat lebih lama.
  Future<List<Map<String, dynamic>>> fetchSessionMessages(
    String sessionId, {
    int limit = 50,
    int offset = 0,
  }) async {
    final safeId = Uri.encodeComponent(sessionId);
    final res = await _http
        .get(_u('/v1/sessions/$safeId/messages?limit=$limit&offset=$offset'),
            headers: _headers)
        .timeout(const Duration(seconds: 15));
    _throwIf(res, 'session messages');
    final json = jsonDecode(res.body) as Map<String, dynamic>;
    final list = json['messages'] as List<dynamic>? ?? [];
    return list.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  Future<bool> deleteSession(String sessionId) async {
    final safeId = Uri.encodeComponent(sessionId);
    final res = await _http
        .delete(_u('/v1/sessions/$safeId'), headers: _headers)
        .timeout(const Duration(seconds: 10));
    if (res.statusCode >= 400) return false;
    final json = jsonDecode(res.body) as Map<String, dynamic>;
    return json['deleted'] == true;
  }

  Future<bool> renameSession(String sessionId, String title) async {
    final safeId = Uri.encodeComponent(sessionId);
    final res = await _http
        .patch(_u('/v1/sessions/$safeId'),
            headers: _headers, body: jsonEncode({'title': title}))
        .timeout(const Duration(seconds: 10));
    if (res.statusCode >= 400) return false;
    final json = jsonDecode(res.body) as Map<String, dynamic>;
    return json['ok'] == true;
  }

  Future<List<Map<String, dynamic>>> listApprovals() async {
    final res = await _http.get(_u('/v1/approvals'), headers: _headers);
    _throwIf(res, 'approvals');
    final json = jsonDecode(res.body) as Map<String, dynamic>;
    final list = json['approvals'] as List<dynamic>? ?? [];
    return list.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  Future<bool> decideApproval(String id, bool approve) async {
    final safeId = Uri.encodeComponent(id);
    final res = await _http.post(
      _u('/v1/approvals/$safeId'),
      headers: _headers,
      body: jsonEncode({'approve': approve, 'actor': 'flutter'}),
    );
    if (res.statusCode >= 400) return false;
    final json = jsonDecode(res.body) as Map<String, dynamic>;
    return json['ok'] == true;
  }

  Future<List<Map<String, dynamic>>> listEvents() async {
    final res = await _http.get(_u('/v1/events'), headers: _headers);
    _throwIf(res, 'events');
    final json = jsonDecode(res.body) as Map<String, dynamic>;
    final list = json['events'] as List<dynamic>? ?? [];
    return list.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  /// Task kanban (GUI-P1-01): read-only, sumber data identik dengan web UI.
  Future<List<Map<String, dynamic>>> listTasks() async {
    final res = await _http.get(_u('/v1/tasks'), headers: _headers);
    _throwIf(res, 'tasks');
    final json = jsonDecode(res.body) as Map<String, dynamic>;
    final list = json['tasks'] as List<dynamic>? ?? [];
    return list.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  /// Daftar file log (GUI-P1-02).
  Future<List<Map<String, dynamic>>> listLogs() async {
    final res = await _http.get(_u('/v1/logs'), headers: _headers);
    _throwIf(res, 'logs');
    final json = jsonDecode(res.body) as Map<String, dynamic>;
    final list = json['logs'] as List<dynamic>? ?? [];
    return list.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  /// Isi satu file log; 404 dilempar sebagai [ApiError.notFound].
  Future<Map<String, dynamic>> fetchLogContent(String name) async {
    final safeName = Uri.encodeComponent(name);
    final res = await _http
        .get(_u('/v1/logs/$safeName'), headers: _headers)
        .timeout(const Duration(seconds: 15));
    _throwIf(res, 'log content');
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  /// Skills listing (GUI-P1-03). Backend mengembalikan `{'error': ...}`
  /// dengan HTTP 200 saat skill API belum terkonfigurasi maupun saat gate
  /// menolak; diangkat menjadi [ApiError] agar UI bisa menampilkannya.
  Future<List<Map<String, dynamic>>> listSkills() async {
    final res = await _http.get(_u('/v1/skills'), headers: _headers);
    _throwIf(res, 'skills');
    final json = jsonDecode(res.body) as Map<String, dynamic>;
    _throwPayloadError(json, 'skills');
    final list = json['skills'] as List<dynamic>? ?? [];
    return list.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  Future<Map<String, dynamic>> sendSkillFeedback(String slug, bool positive) async {
    final safeSlug = Uri.encodeComponent(slug);
    final res = await _http
        .post(_u('/v1/skills/$safeSlug/feedback'),
            headers: _headers, body: jsonEncode({'positive': positive}))
        .timeout(const Duration(seconds: 10));
    _throwIf(res, 'skill feedback');
    final json = jsonDecode(res.body) as Map<String, dynamic>;
    _throwPayloadError(json, 'skill feedback');
    return json;
  }

  Future<Map<String, dynamic>> evaluateSkill(String slug) async {
    final safeSlug = Uri.encodeComponent(slug);
    final res = await _http
        .post(_u('/v1/skills/$safeSlug/evaluate'), headers: _headers)
        .timeout(const Duration(seconds: 30));
    _throwIf(res, 'skill evaluate');
    final json = jsonDecode(res.body) as Map<String, dynamic>;
    _throwPayloadError(json, 'skill evaluate');
    return json;
  }

  Future<Map<String, dynamic>> approveSkill(String slug) async {
    final safeSlug = Uri.encodeComponent(slug);
    final res = await _http
        .post(_u('/v1/skills/$safeSlug/approve'), headers: _headers)
        .timeout(const Duration(seconds: 30));
    _throwIf(res, 'skill approve');
    final json = jsonDecode(res.body) as Map<String, dynamic>;
    _throwPayloadError(json, 'skill approve');
    return json;
  }

  Future<Map<String, dynamic>> rollbackSkill(String slug) async {
    final safeSlug = Uri.encodeComponent(slug);
    final res = await _http
        .post(_u('/v1/skills/$safeSlug/rollback'), headers: _headers)
        .timeout(const Duration(seconds: 15));
    _throwIf(res, 'skill rollback');
    final json = jsonDecode(res.body) as Map<String, dynamic>;
    _throwPayloadError(json, 'skill rollback');
    return json;
  }

  Future<List<Map<String, dynamic>>> fetchSkillHistory(String slug) async {
    final safeSlug = Uri.encodeComponent(slug);
    final res = await _http
        .get(_u('/v1/skills/$safeSlug/history'), headers: _headers)
        .timeout(const Duration(seconds: 10));
    _throwIf(res, 'skill history');
    final json = jsonDecode(res.body) as Map<String, dynamic>;
    _throwPayloadError(json, 'skill history');
    final list = json['history'] as List<dynamic>? ?? [];
    return list.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  /// Skill/gate errors tiba sebagai HTTP 200 dengan kunci `error`
  /// (RuntimeSkillApi), bukan status HTTP — diangkat jadi [ApiError].
  void _throwPayloadError(Map<String, dynamic> json, String what) {
    final error = json['error'];
    if (error is String && error.isNotEmpty) {
      throw ApiError(code: ApiErrorCode.invalidRequest, message: error);
    }
  }

  /// Provider & model manager (GUI-P1-05). Error model typed, cukup
  /// `_throwIf`.
  Future<Map<String, dynamic>> fetchProviders() async {
    final res = await _http
        .get(_u('/v1/providers'), headers: _headers)
        .timeout(const Duration(seconds: 10));
    _throwIf(res, 'providers');
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  /// [providerArg] adalah id provider atau `default` (lepas override);
  /// false bila provider tidak dikenal (404).
  Future<bool> setSessionProvider(String sessionId, String providerArg) async {
    final res = await _http
        .post(_u('/v1/providers/session'),
            headers: _headers,
            body: jsonEncode({'session_id': sessionId, 'provider': providerArg}))
        .timeout(const Duration(seconds: 10));
    if (res.statusCode >= 400) return false;
    final json = jsonDecode(res.body) as Map<String, dynamic>;
    return json['ok'] == true;
  }

  /// Channels setup (GUI-P1-07): status channel gateway + nama env
  /// (read-only).
  Future<Map<String, dynamic>> fetchChannels() async {
    final res = await _http
        .get(_u('/v1/channels'), headers: _headers)
        .timeout(const Duration(seconds: 10));
    _throwIf(res, 'channels');
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  /// Plugin & tools manager (GUI-P1-06): snapshot plugin + consent,
  /// katalog tool registry host, dan status server MCP.
  Future<Map<String, dynamic>> fetchPlugins() async {
    final res = await _http
        .get(_u('/v1/plugins'), headers: _headers)
        .timeout(const Duration(seconds: 10));
    _throwIf(res, 'plugins');
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  /// [action] adalah `grant` atau `revoke`; melempar [ApiError] bila plugin
  /// tidak dikenal / tidak menunggu consent (404) atau body invalid (400).
  Future<Map<String, dynamic>> setPluginConsent(
      String plugin, String action) async {
    final res = await _http
        .post(_u('/v1/plugins/consent'),
            headers: _headers,
            body: jsonEncode({'plugin': plugin, 'action': action}))
        .timeout(const Duration(seconds: 10));
    _throwIf(res, 'plugin consent');
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  /// Bot manager (GUI-P1-04). Backend memakai error model typed
  /// (401/400/404/409/501), jadi cukup `_throwIf`.
  Future<List<Map<String, dynamic>>> listBots() async {
    final res = await _http
        .get(_u('/v1/bots'), headers: _headers)
        .timeout(const Duration(seconds: 10));
    _throwIf(res, 'bots');
    final json = jsonDecode(res.body) as Map<String, dynamic>;
    final list = json['bots'] as List<dynamic>? ?? [];
    return list.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  Future<Map<String, dynamic>> createBot(Map<String, dynamic> body) async {
    final res = await _http
        .post(_u('/v1/bots'), headers: _headers, body: jsonEncode(body))
        .timeout(const Duration(seconds: 10));
    _throwIf(res, 'create bot');
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> updateBot(
    String id,
    Map<String, dynamic> body,
  ) async {
    final safeId = Uri.encodeComponent(id);
    final res = await _http
        .patch(_u('/v1/bots/$safeId'), headers: _headers, body: jsonEncode(body))
        .timeout(const Duration(seconds: 10));
    _throwIf(res, 'update bot');
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  Future<bool> deleteBot(String id) async {
    final safeId = Uri.encodeComponent(id);
    final res = await _http
        .delete(_u('/v1/bots/$safeId'), headers: _headers)
        .timeout(const Duration(seconds: 10));
    if (res.statusCode >= 400) return false;
    final json = jsonDecode(res.body) as Map<String, dynamic>;
    return json['deleted'] == true;
  }

  Future<Map<String, String>> listBotBindings() async {
    final res = await _http
        .get(_u('/v1/bots/bindings'), headers: _headers)
        .timeout(const Duration(seconds: 10));
    _throwIf(res, 'bot bindings');
    final json = jsonDecode(res.body) as Map<String, dynamic>;
    final raw = json['bindings'] as Map? ?? const {};
    return <String, String>{
      for (final e in raw.entries) e.key: '${e.value}',
    };
  }

  /// Security Center (GUI-P1-10): snapshot status keamanan konsolidasi
  /// (read-only, tanpa nilai rahasia).
  Future<Map<String, dynamic>> fetchSecurity() async {
    final res = await _http
        .get(_u('/v1/security'), headers: _headers)
        .timeout(const Duration(seconds: 10));
    _throwIf(res, 'security');
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  /// Audit query browser (GUI-P1-11): GET /v1/audit dengan filter via
  /// query string (tool/session/risk/verdict/taint/since/until/limit/offset).
  Future<Map<String, dynamic>> queryAudit(Map<String, String> query) async {
    final res = await _http
        .get(_u('/v1/audit').replace(queryParameters: query),
            headers: _headers)
        .timeout(const Duration(seconds: 15));
    _throwIf(res, 'audit');
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  /// Automation / cron CRUD (GUI-P1-09). Backend memakai error model
  /// typed (400/404/501), jadi cukup `_throwIf`.
  Future<List<Map<String, dynamic>>> listJobs() async {
    final res = await _http
        .get(_u('/v1/jobs'), headers: _headers)
        .timeout(const Duration(seconds: 10));
    _throwIf(res, 'jobs');
    final json = jsonDecode(res.body) as Map<String, dynamic>;
    final list = json['jobs'] as List<dynamic>? ?? [];
    return list.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  Future<Map<String, dynamic>> createJob(Map<String, dynamic> body) async {
    final res = await _http
        .post(_u('/v1/jobs'), headers: _headers, body: jsonEncode(body))
        .timeout(const Duration(seconds: 10));
    _throwIf(res, 'create job');
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> updateJob(
    String id,
    Map<String, dynamic> body,
  ) async {
    final safeId = Uri.encodeComponent(id);
    final res = await _http
        .patch(_u('/v1/jobs/$safeId'), headers: _headers, body: jsonEncode(body))
        .timeout(const Duration(seconds: 10));
    _throwIf(res, 'update job');
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  Future<bool> deleteJob(String id) async {
    final safeId = Uri.encodeComponent(id);
    final res = await _http
        .delete(_u('/v1/jobs/$safeId'), headers: _headers)
        .timeout(const Duration(seconds: 10));
    if (res.statusCode >= 400) return false;
    final json = jsonDecode(res.body) as Map<String, dynamic>;
    return json['deleted'] == true;
  }

  /// Run now: majukan `next_run` job sehingga tick scheduler berikutnya
  /// (≤20s) mengklaimnya; false bila id asing atau job sedang busy.
  Future<Map<String, dynamic>?> runJobNow(String id) async {
    final safeId = Uri.encodeComponent(id);
    final res = await _http
        .post(_u('/v1/jobs/$safeId/run'), headers: _headers)
        .timeout(const Duration(seconds: 10));
    if (res.statusCode >= 400) return null;
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  Future<bool> bindBot(String botId, String sessionId) async {
    final safeId = Uri.encodeComponent(botId);
    final res = await _http
        .post(_u('/v1/bots/$safeId/bind'),
            headers: _headers, body: jsonEncode({'session_id': sessionId}))
        .timeout(const Duration(seconds: 10));
    if (res.statusCode >= 400) return false;
    final json = jsonDecode(res.body) as Map<String, dynamic>;
    return json['ok'] == true;
  }

  Future<bool> unbindBot(String botId, String sessionId) async {
    final safeId = Uri.encodeComponent(botId);
    final res = await _http
        .post(_u('/v1/bots/$safeId/unbind'),
            headers: _headers, body: jsonEncode({'session_id': sessionId}))
        .timeout(const Duration(seconds: 10));
    if (res.statusCode >= 400) return false;
    final json = jsonDecode(res.body) as Map<String, dynamic>;
    return json['ok'] == true;
  }

  Future<List<Map<String, dynamic>>> listMemories() async {
    final res = await _http.get(_u('/v1/memories'), headers: _headers);
    _throwIf(res, 'memories');
    final json = jsonDecode(res.body) as Map<String, dynamic>;
    final list = json['memories'] as List<dynamic>? ?? [];
    return list.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  Future<bool> deleteMemory(String id) async {
    final safeId = Uri.encodeComponent(id);
    final res = await _http.delete(_u('/v1/memories/$safeId'), headers: _headers)
        .timeout(const Duration(seconds: 10));
    if (res.statusCode >= 400) return false;
    final json = jsonDecode(res.body) as Map<String, dynamic>;
    return json['deleted'] == true;
  }

  Future<String> sendMessage(
    String text, {
    String sessionKey = 'flutter:default',
  }) async {
    final res = await _http
        .post(
          _u('/v1/messages'),
          headers: _headers,
          body: jsonEncode({
            'text': text,
            'session_key': sessionKey,
            'user_key': 'flutter',
          }),
        )
        .timeout(const Duration(seconds: 180));
    _throwIf(res, 'messages');
    final json = jsonDecode(res.body) as Map<String, dynamic>;
    return json['text'] as String? ?? '';
  }

  /// Typed GenUI action (GUI-P0-04): kirim aksi form/tombol ke endpoint
  /// tervalidasi daemon. Melempar exception bila ditolak (400) atau daemon
  /// lama tanpa dukungan (501).
  Future<String> submitUiAction(
    String sessionKey,
    String actionId,
    Map<String, dynamic> values,
  ) async {
    final res = await _http
        .post(
          _u('/v1/ui/actions'),
          headers: _headers,
          body: jsonEncode({
            'session_key': sessionKey,
            'action_id': actionId,
            'values': values,
          }),
        )
        .timeout(const Duration(seconds: 180));
    _throwIf(res, 'ui actions');
    final json = jsonDecode(res.body) as Map<String, dynamic>;
    return json['text'] as String? ?? '';
  }

  Future<void> respondConfirm(String id, bool allow) async {
    final ok = await decideApproval(id, allow);
    if (!ok) throw StateError('Approval $id tidak lagi pending atau kedaluwarsa.');
  }

  /// Live push event runtime (WebSocket `/v1/stream`): hanya frame
  /// `{'type': 'event', 'event': {...}}` yang di-yield; frame lain
  /// (typing/text/done/confirm/confirm_result) diabaikan agar feed admin
  /// tidak tercemar percakapan. Tidak ada pesan yang dikirim lewat socket
  /// ini, sehingga server tidak menutup koneksi setelah satu turn.
  /// Koneksi yang putus mengalirkan onDone/onError — reconnection adalah
  /// tanggung jawab pemanggil (AdminEventFeed).
  Stream<Map<String, dynamic>> streamEvents() async* {
    final base = baseUrl.replaceAll(RegExp(r'/$'), '');
    final wsBase = base.startsWith('https')
        ? base.replaceFirst('https', 'wss')
        : base.replaceFirst('http', 'ws');
    final ticket = await _requestStreamTicket(base);
    final uri = Uri.parse('$wsBase/v1/stream').replace(
      queryParameters: ticket == null ? {} : {'ticket': ticket},
    );
    final channel = WebSocketChannel.connect(uri);
    try {
      await channel.ready.timeout(const Duration(seconds: 10));
      await for (final raw in channel.stream) {
        if (raw is! String) continue;
        final Map<String, dynamic> frame;
        try {
          frame = jsonDecode(raw) as Map<String, dynamic>;
        } catch (_) {
          continue;
        }
        if (frame['type'] != 'event') continue;
        final event = frame['event'];
        if (event is Map<String, dynamic>) yield event;
      }
    } finally {
      try {
        await channel.sink
            .close()
            .timeout(const Duration(seconds: 5), onTimeout: () {});
      } catch (_) {
        // best-effort
      }
    }
  }

  Stream<Map<String, dynamic>> streamChat(
    String text, {
    String sessionKey = 'flutter:default',
  }) async* {
    final base = baseUrl.replaceAll(RegExp(r'/$'), '');
    final wsBase = base.startsWith('https')
        ? base.replaceFirst('https', 'wss')
        : base.replaceFirst('http', 'ws');
    final ticket = await _requestStreamTicket(base);
    final uri = Uri.parse('$wsBase/v1/stream').replace(
      queryParameters: ticket == null ? {} : {'ticket': ticket},
    );
    final channel = WebSocketChannel.connect(uri);
    try {
      await channel.ready.timeout(const Duration(seconds: 10));
      channel.sink.add(jsonEncode({
        'text': text,
        'session_key': sessionKey,
        'user_key': 'flutter',
      }));
      await for (final raw in channel.stream.timeout(const Duration(seconds: 180))) {
        if (raw is String) {
          yield Map<String, dynamic>.from(jsonDecode(raw) as Map);
        } else {
          yield <String, dynamic>{'type': 'error', 'message': 'bad frame'};
        }
      }
    } finally {
      // Teardown tidak boleh menggantung: bila upgrade gagal atau koneksi
      // putus mendadak, sink.close() bisa menunggu close frame yang tidak
      // pernah datang. Batasi dengan timeout dan abaikan kegagalannya —
      // error asli tetap diangkat ke pemanggil.
      try {
        await channel.sink
            .close()
            .timeout(const Duration(seconds: 5), onTimeout: () {});
      } catch (_) {
        // best-effort
      }
    }
  }

  void _throwIf(http.Response res, String what) {
    if (res.statusCode >= 400) {
      throw ApiError.fromResponse(res.statusCode, res.body);
    }
  }

  /// Exchanges the Bearer token for a short-lived one-time stream ticket.
  /// The main token never travels in a URL query.
  Future<String?> _requestStreamTicket(String base) async {
    try {
      final res = await _http
          .post(Uri.parse('$base/v1/auth/ticket'), headers: _headers)
          .timeout(const Duration(seconds: 10));
      if (res.statusCode >= 400) return null;
      final json = jsonDecode(res.body) as Map<String, dynamic>;
      return json['ticket'] as String?;
    } catch (_) {
      return null;
    }
  }

  void close() => _http.close();
}

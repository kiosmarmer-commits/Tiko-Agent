import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

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
      body: jsonEncode({'approve': approve}),
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

  Future<void> respondConfirm(String id, bool allow) async {
    final ok = await decideApproval(id, allow);
    if (!ok) throw StateError('Approval $id tidak lagi pending atau kedaluwarsa.');
  }

  Stream<Map<String, dynamic>> streamChat(
    String text, {
    String sessionKey = 'flutter:default',
  }) async* {
    final base = baseUrl.replaceAll(RegExp(r'/$'), '');
    final wsBase = base.startsWith('https')
        ? base.replaceFirst('https', 'wss')
        : base.replaceFirst('http', 'ws');
    // QueryParameters performs correct escaping for tokens containing +, &, etc.
    final uri = Uri.parse('$wsBase/v1/stream').replace(
      queryParameters: {'token': token},
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
      await channel.sink.close();
    }
  }

  void _throwIf(http.Response res, String what) {
    if (res.statusCode >= 400) {
      throw Exception('$what ${res.statusCode}: ${res.body}');
    }
  }

  void close() => _http.close();
}

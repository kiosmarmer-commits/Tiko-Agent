import 'dart:convert';
import 'dart:io';

import 'package:agent_core/agent_core.dart';
import 'package:agent_gateway/agent_gateway.dart';
import 'package:test/test.dart';

void main() {
  late HttpApiServer server;
  late String? capturedSession;
  late String? capturedAction;
  late Map<String, dynamic> capturedValues;
  Object? handlerBehavior;

  setUp(() async {
    capturedSession = null;
    capturedAction = null;
    capturedValues = {};
    handlerBehavior = null;
    server = HttpApiServer(
      onMessage: (_) async => 'ok',
      authToken: 'manager-token-0123456789abcdef',
      port: 0,
      uiActionHandler: (sessionKey, actionId, values) async {
        capturedSession = sessionKey;
        capturedAction = actionId;
        capturedValues = values;
        if (handlerBehavior is GenUiActionRejected) throw handlerBehavior!;
        if (handlerBehavior is Exception) throw handlerBehavior!;
        return {'ok': true, 'text': 'aksi $actionId dijalankan'};
      },
    );
    await server.start();
  });

  tearDown(() async {
    await server.stop();
  });

  Future<Map<String, dynamic>> post(
    Object? body, {
    bool auth = true,
  }) async {
    final client = HttpClient();
    try {
      final uri = Uri.parse('http://127.0.0.1:${server.boundPort}/v1/ui/actions');
      final request = await client.openUrl('POST', uri);
      request.headers.set('content-type', 'application/json');
      if (auth) request.headers.set('authorization', 'Bearer manager-token-0123456789abcdef');
      request.add(utf8.encode(jsonEncode(body)));
      final response = await request.close();
      final text = await response.transform(utf8.decoder).join();
      return {'status': response.statusCode, 'body': jsonDecode(text) as Map<String, dynamic>};
    } finally {
      client.close(force: true);
    }
  }

  test('POST /v1/ui/actions meneruskan aksi tervalidasi ke handler', () async {
    final result = await post({
      'session_key': 'flutter:default',
      'action_id': 'submit_form',
      'values': {'kota': 'Bandung'},
    });
    expect(result['status'], 200);
    expect(result['body']['ok'], isTrue);
    expect(result['body']['text'], 'aksi submit_form dijalankan');
    expect(capturedSession, 'flutter:default');
    expect(capturedAction, 'submit_form');
    expect(capturedValues, {'kota': 'Bandung'});
  });

  test('action id dengan karakter tidak aman ditolak 400', () async {
    final result = await post({
      'session_key': 'flutter:default',
      'action_id': 'bad id!!',
      'values': {},
    });
    expect(result['status'], 400);
    expect(result['body']['error'], 'invalid ui action request');
  });

  test('session_key kosong ditolak 400', () async {
    final result = await post({'session_key': '', 'action_id': 'ok'});
    expect(result['status'], 400);
  });

  test('GenUiActionRejected dari handler menjadi 400', () async {
    handlerBehavior = const GenUiActionRejected('aksi sudah kedaluwarsa');
    final result = await post({
      'session_key': 'flutter:default',
      'action_id': 'ok',
      'values': {},
    });
    expect(result['status'], 400);
    expect(result['body']['ok'], isFalse);
    expect(result['body']['error'], 'aksi sudah kedaluwarsa');
  });

  test('endpoint 501 bila handler tidak dikonfigurasi', () async {
    final bare = HttpApiServer(
      onMessage: (_) async => 'ok',
      authToken: 'manager-token-0123456789abcdef',
      port: 0,
    );
    await bare.start();
    try {
      final client = HttpClient();
      final uri = Uri.parse('http://127.0.0.1:${bare.boundPort}/v1/ui/actions');
      final request = await client.openUrl('POST', uri);
      request.headers.set('authorization', 'Bearer manager-token-0123456789abcdef');
      request.headers.set('content-type', 'application/json');
      request.add(utf8.encode(jsonEncode({'session_key': 's', 'action_id': 'a'})));
      final response = await request.close();
      expect(response.statusCode, 501);
      client.close(force: true);
    } finally {
      await bare.stop();
    }
  });

  test('endpoint memerlukan auth', () async {
    final result = await post({'session_key': 's', 'action_id': 'a'}, auth: false);
    expect(result['status'], 401);
  });
}

import 'dart:async';
import 'dart:convert';

import 'package:agent_tools/src/api_server.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';


ApiRoute _pingRoute() => ApiRoute(
  path: '/api/v1/ping',
  method: ApiMethod.get,
  authRequired: true,
  handler: (req) async => ApiResponse(body: {'pong': true}),
);

void main() {
  late ApiServer server;

  setUp(() {
    server = ApiServer(
      config: const ApiServerConfig(
        host: '127.0.0.1',
        port: 0,
        authToken: 'token-rahasia-panjang',
        corsOrigins: ['https://app.example'],
        maxRequestSize: 64,
      ),
      routes: [_pingRoute()],
    );
  });

  tearDown(() async {
    await server.stop();
  });

  Future<Uri> base() async {
    final port = server.port!;
    return Uri.parse('http://127.0.0.1:$port');
  }

  test('token benar diterima, token salah ditolak 401', () async {
    await server.start();
    final url = await base();
    final ok = await http.get(
      url.replace(path: '/api/v1/ping'),
      headers: {'Authorization': 'Bearer token-rahasia-panjang'},
    );
    expect(ok.statusCode, isNot(401));
    final bad = await http.get(
      url.replace(path: '/api/v1/ping'),
      headers: {'Authorization': 'Bearer token-salah'},
    );
    expect(bad.statusCode, 401);
  });

  test('auth fail-closed: tanpa token dikonfigurasi -> 401, token otomatis', () async {
    final open = ApiServer(
      config: const ApiServerConfig(host: '127.0.0.1', port: 0),
      routes: [_pingRoute()],
    );
    await open.start();
    try {
      expect(open.effectiveAuthToken, isNotNull);
      expect(open.effectiveAuthToken!.length, 64);
      final url = Uri.parse('http://127.0.0.1:${open.port}');
      final res = await http.get(url.replace(path: '/api/v1/ping'));
      expect(res.statusCode, 401);
      final ok = await http.get(
        url.replace(path: '/api/v1/ping'),
        headers: {'Authorization': 'Bearer ${open.effectiveAuthToken}'},
      );
      expect(ok.statusCode, isNot(401));
    } finally {
      await open.stop();
    }
  });

  test('body melebihi maxRequestSize -> 413', () async {
    await server.start();
    final url = await base();
    final res = await http.post(
      url.replace(path: '/api/v1/chat'),
      headers: {
        'Authorization': 'Bearer token-rahasia-panjang',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({'message': 'x' * 4096}),
    );
    expect(res.statusCode, 413);
  });

  test('CORS: origin terdaftar dapat ACAO, asing tidak', () async {
    await server.start();
    final url = await base();
    final allowed = await http.get(
      url.replace(path: '/api/v1/ping'),
      headers: {
        'Authorization': 'Bearer token-rahasia-panjang',
        'Origin': 'https://app.example',
      },
    );
    expect(allowed.headers['access-control-allow-origin'],
        'https://app.example');
    final denied = await http.get(
      url.replace(path: '/api/v1/ping'),
      headers: {
        'Authorization': 'Bearer token-rahasia-panjang',
        'Origin': 'https://evil.example',
      },
    );
    expect(denied.headers['access-control-allow-origin'], isNull);
  });

  test('onStart terpanggil sebelum request pertama dilayani', () async {
    final events = <String>[];
    final ordered = ApiServer(
      config: const ApiServerConfig(
        host: '127.0.0.1',
        port: 0,
        authToken: 'token-rahasia-panjang',
      ),
      routes: [_pingRoute()],
      onStart: (s) async {
        events.add('start');
      },
    );
    await ordered.start();
    final url = Uri.parse('http://127.0.0.1:${ordered.port}');
    await http.get(url.replace(path: '/api/v1/ping'));
    expect(events.first, 'start');
    await ordered.stop();
  });

  test('start() tidak memblokir dan stop() memicu onStop tepat sekali', () async {
    var stopCount = 0;
    final tracked = ApiServer(
      config: const ApiServerConfig(host: '127.0.0.1', port: 0),
      onStop: (s) async {
        stopCount++;
      },
    );
    await tracked.start().timeout(const Duration(seconds: 5));
    expect(tracked.status.value, 'running');
    await tracked.stop();
    expect(stopCount, 1);
    expect(tracked.status.value, 'stopped');
  });

  test('dua server pada port sama: yang kedua gagal bind (shared:false)',
      () async {
    await server.start();
    final port = server.port!;
    final second = ApiServer(
      config: ApiServerConfig(host: '127.0.0.1', port: port),
    );
    await expectLater(second.start(), throwsA(anything));
    await second.stop();
  });
}

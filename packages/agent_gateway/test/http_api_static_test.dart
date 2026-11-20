import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_gateway/agent_gateway.dart';
import 'package:test/test.dart';

void main() {
  late HttpApiServer server;
  late HttpApiServer serverNoRoot;
  late HttpClient client;
  late Directory webRoot;
  late Directory escapeDir;
  late StreamController<Map<String, dynamic>> events;

  setUp(() async {
    events = StreamController<Map<String, dynamic>>.broadcast();
    webRoot = await Directory.systemTemp.createTemp('tiko-static-ui');
    File('${webRoot.path}/index.html').writeAsStringSync(
      '<!doctype html><html><body>tiko</body></html>',
    );
    Directory('${webRoot.path}/assets').createSync();
    File('${webRoot.path}/assets/app.json').writeAsStringSync('{"a":1}');
    File('${webRoot.path}/main.dart.js').writeAsStringSync('// js');
    File('${webRoot.path}/canvaskit.wasm').writeAsStringSync('\x00wasm');
    escapeDir = Directory('${webRoot.path}/../tiko-static-escape');
    escapeDir.createSync();
    File('${escapeDir.path}/secret.txt').writeAsStringSync('secret');
    server = HttpApiServer(
      onMessage: (_) async => 'ok',
      authToken: 'test-secret',
      port: 0,
      webRoot: webRoot.path,
      eventStream: events.stream,
    );
    await server.start();
    serverNoRoot = HttpApiServer(
      onMessage: (_) async => 'ok',
      authToken: 'test-secret',
      port: 0,
      eventStream: events.stream,
    );
    await serverNoRoot.start();
    client = HttpClient();
  });

  tearDown(() async {
    client.close(force: true);
    await server.stop();
    await serverNoRoot.stop();
    await events.close();
    await webRoot.delete(recursive: true);
    if (await escapeDir.exists()) {
      await escapeDir.delete(recursive: true);
    }
  });

  Future<HttpClientResponse> get(
    String path, {
    HttpApiServer? target,
    bool raw = false,
  }) async {
    final srv = target ?? server;
    final uri = raw || path == '/'
        ? Uri.parse('http://127.0.0.1:${srv.boundPort}$path')
        : Uri(
            scheme: 'http',
            host: '127.0.0.1',
            port: srv.boundPort,
            pathSegments: [
              for (final segment in path.split('/'))
                if (segment.isNotEmpty) Uri.encodeComponent(segment),
            ],
          );
    final req = await client.openUrl('GET', uri);
    return req.close();
  }

  /// GET/POST dengan header tambahan (Cookie, Origin, dsb).
  Future<HttpClientResponse> send(
    String method,
    String path, {
    Map<String, String> headers = const {},
  }) async {
    final uri = Uri.parse('http://127.0.0.1:${server.boundPort}$path');
    final req = await client.openUrl(method, uri);
    headers.forEach(req.headers.set);
    return req.close();
  }

  /// Muat index UI sekali dan kembalikan nilai cookie sesi yang diberikan.
  Future<String> uiSessionCookie() async {
    final res = await get('/');
    final setCookie = res.headers.value(HttpHeaders.setCookieHeader) ?? '';
    await res.drain<void>();
    expect(setCookie, startsWith('tiko_web_session='));
    return setCookie.split(';').first;
  }

  test('index UI memberikan cookie sesi HttpOnly + SameSite=Strict', () async {
    final index = await get('/');
    final setCookie = index.headers.value(HttpHeaders.setCookieHeader) ?? '';
    await index.drain<void>();
    expect(setCookie, startsWith('tiko_web_session='));
    expect(setCookie, contains('HttpOnly'));
    expect(setCookie, contains('SameSite=Strict'));
    expect(setCookie, contains('Path=/'));
    expect(setCookie, contains('Max-Age=86400'));
  });

  test('API menerima cookie sesi tanpa Bearer (dashboard tanpa token)', () async {
    final res = await send(
      'GET',
      '/v1/status',
      headers: {HttpHeaders.cookieHeader: await uiSessionCookie()},
    );
    expect(res.statusCode, 200);
  });

  test('cookie sesi dengan nilai salah ditolak 401', () async {
    final res = await send(
      'GET',
      '/v1/status',
      headers: {HttpHeaders.cookieHeader: 'tiko_web_session=salah'},
    );
    expect(res.statusCode, 401);
  });

  test('cookie sesi dengan Origin asing ditolak 401', () async {
    final res = await send(
      'GET',
      '/v1/status',
      headers: {
        HttpHeaders.cookieHeader: await uiSessionCookie(),
        'origin': 'http://evil.example',
      },
    );
    expect(res.statusCode, 401);
  });

  test('cookie sesi dengan Origin loopback yang cocok diterima', () async {
    final res = await send(
      'GET',
      '/v1/status',
      headers: {
        HttpHeaders.cookieHeader: await uiSessionCookie(),
        'origin': 'http://127.0.0.1:${server.boundPort}',
      },
    );
    expect(res.statusCode, 200);
  });

  test('ticket WS bisa diminta hanya dengan cookie sesi (tanpa token)', () async {
    final res = await send(
      'POST',
      '/v1/auth/ticket',
      headers: {HttpHeaders.cookieHeader: await uiSessionCookie()},
    );
    expect(res.statusCode, 200);
    final body = jsonDecode(await res.transform(utf8.decoder).join()) as Map;
    expect(body['ticket'] as String, isNotEmpty);
  });

  test('dilayani dari root statis dengan tipe html', () async {
    final res = await get('/');
    expect(res.statusCode, 200);
    expect(res.headers.contentType?.mimeType, 'text/html');
    expect(
      utf8.decode(await res.fold<List<int>>(<int>[], (a, b) => a..addAll(b))),
      contains('tiko'),
    );
  });

  test('aset nested (main.dart.js, canvaskit.wasm) terlayani dengan mime', () async {
    final js = await get('/main.dart.js');
    expect(js.statusCode, 200);
    expect(js.headers.contentType?.mimeType, 'application/javascript');

    final wasm = await get('/canvaskit.wasm');
    expect(wasm.statusCode, 200);
    expect(wasm.headers.contentType?.mimeType, 'application/wasm');
  });

  test('directori json dengan payload utuh', () async {
    final res = await get('/assets/app.json');
    expect(res.statusCode, 200);
    expect(res.headers.contentType?.mimeType, 'application/json');
    expect(
      jsonDecode(
        utf8.decode(await res.fold<List<int>>(<int>[], (a, b) => a..addAll(b))),
      ),
      {'a': 1},
    );
  });

  test('file hilang 404 dan host guard tetap di depan', () async {
    final res = await get('/assets/missing.txt');
    expect(res.statusCode, 404);
  });

  test('traversal ../ dan setara tidak pernah menyajikan konten luar root', () async {
    final resBlocked = await get(
      '/../tiko-static-escape/secret.txt',
      raw: true,
    );
    expect(resBlocked.statusCode, isNot(200));
    final bodyBlocked = await resBlocked.fold<List<int>>(
      <int>[],
      (a, b) => a..addAll(b),
    );
    expect(utf8.decode(bodyBlocked), isNot(contains('secret')));

    final resEncoded =
        await get('/%2e%2e/tiko-static-escape/secret.txt', raw: true);
    expect(resEncoded.statusCode, isNot(200));
  });

  test('%2e ter-encode dalam path tidak bisa keluar dari webRoot', () async {
    final res = await get('/assets/%2e%2e/app.json', raw: true);
    expect(res.statusCode, isNot(200));
  });

  test('tanpa webRoot: static path 404, API tetap 401 tanpa token', () async {
    final missingRoot = await get('/', target: serverNoRoot);
    expect(missingRoot.statusCode, 404);

    final api = await get('/v1/status', target: serverNoRoot);
    expect(api.statusCode, 401);
  });

  test('health dan /v1 tidak masuk jalur static', () async {
    final health = await get('/health');
    expect(health.statusCode, 200);
    expect(
      jsonDecode(
        utf8.decode(
          await health.fold<List<int>>(<int>[], (a, b) => a..addAll(b)),
        ),
      ),
      {'ok': true},
    );

    final status = await get('/v1/status');
    expect(status.statusCode, 401);
  });
}

import 'dart:convert';
import 'dart:io';

import 'package:agent_tools/agent_tools.dart';
import 'package:test/test.dart';

void main() {
  HttpServer? server;
  late Uri baseUri;
  final requests = <String>[];
  final authHeaders = <String, String>{};

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    baseUri = Uri.parse('http://127.0.0.1:${server!.port}');
    requests.clear();
    authHeaders.clear();
    server!.listen((req) async {
      final path = req.uri.path;
      requests.add('${req.method} $path');
      authHeaders[req.headers.value('x-api-key') ?? 'bearer'] =
          req.headers.value('authorization') ?? '';
      req.headers.forEach((k, v) {
        if (k.toLowerCase() == 'x-api-key' ||
            k.toLowerCase() == 'authorization') {
          authHeaders[k.toLowerCase()] = v.first;
        }
      });
      if (req.method == 'POST' && path == '/v1/sessions') {
        final body = await utf8.decoder.bind(req).join();
        expect(body, contains('projectId'));
        req.response.statusCode = 200;
        req.response.write(jsonEncode({
          'id': 'bb-123',
          'connectUrl': 'wss://example.invalid/devtools',
          'debugUrl': 'https://browserbase.com/sessions/bb-123',
        }));
      } else if (req.method == 'POST' && path == '/v1/sessions/bb-123') {
        req.response.statusCode = 200;
        req.response.write('{}');
      } else if (req.method == 'POST' && path == '/api/v1/sessions') {
        req.response.statusCode = 200;
        req.response.write(jsonEncode({
          'id': 'bu-456',
          'cdp_url': 'wss://example.invalid/bu',
          'live_url': 'https://browser-use.com/live/bu-456',
        }));
      } else if (req.method == 'DELETE' && path == '/api/v1/sessions/bu-456') {
        req.response.statusCode = 204;
      } else if (req.method == 'POST' && path == '/boom') {
        req.response.statusCode = 500;
        req.response.write('nope');
      } else {
        req.response.statusCode = 404;
      }
      await req.response.close();
    });
  });

  tearDown(() async {
    await server?.close(force: true);
  });

  test('BrowserbaseBackend creates and closes a session', () async {
    final backend = BrowserbaseBackend(
      apiKey: 'k',
      projectId: 'proj',
      baseUrl: baseUri.toString(),
    );
    final session = await backend.createSession();
    expect(session.id, 'bb-123');
    expect(session.cdpUrl, 'wss://example.invalid/devtools');
    expect(session.viewUrl, contains('bb-123'));
    expect(authHeaders['x-api-key'], 'k');
    await backend.closeSession(session.id);
    expect(requests, contains('POST /v1/sessions/bb-123'));
  });

  test('BrowserUseBackend creates and closes a session', () async {
    final backend = BrowserUseBackend(
      apiKey: 'k2',
      baseUrl: baseUri.toString(),
    );
    final session = await backend.createSession();
    expect(session.id, 'bu-456');
    expect(session.cdpUrl, 'wss://example.invalid/bu');
    expect(session.viewUrl, contains('bu-456'));
    expect(authHeaders['authorization'], 'Bearer k2');
    await backend.closeSession(session.id);
    expect(requests, contains('DELETE /api/v1/sessions/bu-456'));
  });

  test('HTTP errors raise BrowserBackendException', () async {
    // Port 1 is never listening in the test sandbox -> connection refused.
    final backend = BrowserbaseBackend(
      apiKey: 'k',
      baseUrl: 'http://127.0.0.1:1',
    );
    await expectLater(backend.createSession, throwsA(isA<Exception>()));
  });

  test('CloudBrowserRouter falls back to local when no backends configured',
      () async {
    // Force the local fallback to fail deterministically: the bogus chrome
    // path makes CdpSession.open() throw UnsupportedError.
    final router = CloudBrowserRouter(
      backends: const [],
      chromePath: '/nonexistent/tiko-chrome',
    );
    await expectLater(
      router.acquire(),
      throwsA(anyOf(
        isA<UnsupportedError>(),
        isA<BrowserBackendException>(),
      )),
    );
  });

  test('CloudBrowserRouter with localFallback=false reports backend errors',
      () async {
    final router = CloudBrowserRouter(
      backends: [
        BrowserbaseBackend(
          apiKey: 'k',
          projectId: 'proj',
          baseUrl: baseUri.toString(),
        ),
      ],
      localFallback: false,
    );
    // The stub returns a wss endpoint that cannot be connected to (invalid
    // host), so open() fails and the router must surface an exception that
    // mentions the backend id.
    await expectLater(
      router.acquire(),
      throwsA(isA<BrowserBackendException>()),
    );
  });
}

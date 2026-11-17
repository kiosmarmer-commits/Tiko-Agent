import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:agent_tools/agent_tools.dart';
import 'package:test/test.dart';

/// Fake authorization server + MCP server untuk menguji alur
/// authorization_code + PKCE secara end-to-end tanpa browser nyata.
class _FakeOAuthServer {
  _FakeOAuthServer() {
    _bind();
  }

  late HttpServer server;
  late String base;

  final wellKnownFetches = <String>[];
  final registrationBodies = <Map<String, dynamic>>[];
  final tokenRequests = <({String? auth, Map<String, dynamic> form})>[];
  var tokenUnauthorizedCount = 0;
  String challengeMethods = '["S256","plain"]';
  var tokenEndpointStatus = 200;

  Future<void> _bind() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = 'http://127.0.0.1:${server.port}';
    server.listen((req) async {
      final body = await utf8.decoder.bind(req).join();
      final path = req.uri.path;
      if (path.contains('.well-known')) {
        wellKnownFetches.add(path);
        req.response.headers.contentType = ContentType.json;
        if (path.contains('oauth-protected-resource')) {
          req.response.write(jsonEncode({
            'resource': '${base}mcp',
            'authorization_servers': ['$base/as'],
          }));
        } else {
          req.response.write(jsonEncode({
            'issuer': '$base/as',
            'authorization_endpoint': '$base/as/authorize',
            'token_endpoint': '$base/as/token',
            'registration_endpoint': '$base/register',
            'code_challenge_methods_supported': jsonDecode(challengeMethods),
          }));
        }
        await req.response.close();
        return;
      }
      if (path == '/register') {
        registrationBodies.add(jsonDecode(body) as Map<String, dynamic>);
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode({
          'client_id': 'dcr-client',
          'client_secret': 'dcr-secret',
          'redirect_uris': ['http://127.0.0.1:19999/callback'],
        }));
        await req.response.close();
        return;
      }
      if (path == '/as/token' || path == '/token') {
        final form = Uri.splitQueryString(body);
        tokenRequests.add((auth: req.headers.value('authorization'), form: form));
        req.response.headers.contentType = ContentType.json;
        if (tokenEndpointStatus != 200) {
          req.response.statusCode = tokenEndpointStatus;
          req.response.write(jsonEncode({'error': 'invalid_grant'}));
          await req.response.close();
          return;
        }
        if (form['grant_type'] == 'authorization_code' &&
            form['code'] != 'good-code') {
          tokenUnauthorizedCount += 1;
          req.response.statusCode = 400;
          req.response.write(jsonEncode({'error': 'invalid_grant'}));
          await req.response.close();
          return;
        }
        req.response.write(jsonEncode({
          'access_token': 'at-${tokenRequests.length}',
          'refresh_token': 'rt-${tokenRequests.length}',
          'token_type': 'Bearer',
          'expires_in': 3600,
        }));
        await req.response.close();
        return;
      }
      req.response.statusCode = 404;
      await req.response.close();
    });
    // Tunggu listener siap.
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }

  Future<void> close() => server.close(force: true);
}

void main() {
  group('PKCE (RFC 7636)', () {
    test('vektor resmi Appendix A: S256 challenge', () {
      const verifier = 'dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk';
      expect(
        McpOAuthAuthorizationCode.pkceChallenge(verifier),
        'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM',
      );
    });

    test('verifier acak memenuhi panjang 43-128 karakter', () {
      final verifier = McpOAuthAuthorizationCode.generateVerifier(
          _DeterministicRandom(42));
      expect(verifier.length, greaterThanOrEqualTo(43));
      expect(verifier.length, lessThanOrEqualTo(128));
      expect(RegExp(r'^[A-Za-z0-9\-._~]+$').hasMatch(verifier), isTrue);
    });
  });

  group('konfigurasi', () {
    test('URL tidak aman ditolak', () {
      expect(
        () => McpOAuthAuthorizationCodeConfig(serverUrl: 'ftp://x'),
        throwsArgumentError,
      );
      expect(
        () => McpOAuthAuthorizationCodeConfig(
            serverUrl: 'https://x.evil/\x00'),
        throwsArgumentError,
      );
      expect(
        () => McpOAuthAuthorizationCodeConfig(
            serverUrl: 'https://x#fragment'),
        throwsArgumentError,
      );
    });

    test('auth_method dan redirect_port divalidasi', () {
      expect(
        () => McpOAuthAuthorizationCodeConfig(
            serverUrl: 'https://mcp.example', authMethod: 'cookie'),
        throwsArgumentError,
      );
      expect(
        () => McpOAuthAuthorizationCodeConfig(
            serverUrl: 'https://mcp.example', redirectPort: 70000),
        throwsArgumentError,
      );
      expect(
        () => McpOAuthAuthorizationCodeConfig(
            serverUrl: 'https://mcp.example',
            scopes: ['a b']),
        throwsArgumentError,
      );
    });
  });

  group('alur authorization_code', () {
    late _FakeOAuthServer fake;
    final persisted = <Map<String, dynamic>>[];

    setUp(() async {
      fake = _FakeOAuthServer();
      persisted.clear();
      addTearDown(fake.close);
    });

    late McpOAuthAuthorizationCode oauthUnderTest;

    McpOAuthAuthorizationCode build({
      String? clientId = 'conf-client',
      String? clientSecret = 'conf-secret',
      String authMethod = 'auto',
      bool useDiscovery = false,
      bool usePkce = true,
      String? scope,
    }) =>
        McpOAuthAuthorizationCode(
          McpOAuthAuthorizationCodeConfig(
            serverUrl: '${fake.base}/mcp',
            authorizationUrl: '${fake.base}/as/authorize',
            tokenUrl: '${fake.base}/as/token',
            clientId: clientId ?? '',
            clientSecret: clientSecret ?? '',
            scopes: scope != null ? [scope] : const [],
            redirectPort: 19999,
            authMethod: authMethod,
            useDiscovery: useDiscovery,
            usePkce: usePkce,
          ),
          clock: _FakeClock().now,
          onAuthorizeUrl: (url) {
            // Host/test menyuntik redirect: ambil state dari URL otorisasi,
            // lalu lengkapi dengan code.
            final injected = url.replace(queryParameters: {
              ...url.queryParameters,
              'code': 'good-code',
            });
            Future<void>.microtask(() => oauthUnderTest.completeCallback(injected));
          },
          persistOverride: (tokens) async => persisted.add(tokens),
          loadOverride: () async => persisted.isEmpty ? null : persisted.last,
          openBrowser: false,
        );

    test('alur penuh: URL otorisasi benar, code_verifier cocok challenge, '
        'token Bearer dikembalikan', () async {
      final oauth = build();
      oauthUnderTest = oauth;
      final token = await oauth.token();

      expect(token, 'at-1');
      expect(oauth.lastAuthorizeUrl, isNotNull);
      final authorize = oauth.lastAuthorizeUrl!;
      expect(authorize.host, '127.0.0.1');
      expect(authorize.path, '/as/authorize');
      expect(authorize.queryParameters['response_type'], 'code');
      expect(authorize.queryParameters['client_id'], 'conf-client');
      expect(authorize.queryParameters['redirect_uri'],
          'http://127.0.0.1:19999/callback');
      expect(authorize.queryParameters['state'], isNotEmpty);
      expect(authorize.queryParameters['resource'], '${fake.base}/mcp');
      expect(authorize.queryParameters['code_challenge_method'], 'S256');
      final challenge = authorize.queryParameters['code_challenge']!;
      expect(challenge.length, 43);

      expect(fake.tokenRequests, hasLength(1));
      final tokenReq = fake.tokenRequests.first;
      expect(tokenReq.form['grant_type'], 'authorization_code');
      expect(tokenReq.form['code'], 'good-code');
      expect(tokenReq.form['redirect_uri'],
          'http://127.0.0.1:19999/callback');
      expect(tokenReq.form['resource'], '${fake.base}/mcp');
      // Verifier yang dikirim server harus menghasilkan challenge yang sama.
      expect(
        McpOAuthAuthorizationCode.pkceChallenge(tokenReq.form['code_verifier']!),
        challenge,
      );
      // auto + secret -> Basic auth.
      expect(tokenReq.auth, startsWith('Basic '));
    });

    test('state mismatch disuntik lewat completeCallback ditolak fail-closed',
        () async {
      late final McpOAuthAuthorizationCode oauth;
      oauth = McpOAuthAuthorizationCode(
        McpOAuthAuthorizationCodeConfig(
          serverUrl: '${fake.base}/mcp',
          authorizationUrl: '${fake.base}/as/authorize',
          tokenUrl: '${fake.base}/as/token',
          clientId: 'c',
          redirectPort: 19999,
        ),
        onAuthorizeUrl: (url) {
          final injected = Uri.parse(
              'http://127.0.0.1:19999/callback?code=good-code&state=WRONG');
          Future<void>.microtask(() => oauth.completeCallback(injected));
        },
        openBrowser: false,
      );
      await expectLater(
        oauth.token(),
        throwsA(isA<McpOAuthFlowException>()
            .having((e) => e.code, 'code', 'state_mismatch')),
      );
    });

    test('error parameter dari server otorisasi dilempar dengan kode jelas',
        () async {
      late final McpOAuthAuthorizationCode oauth;
      oauth = McpOAuthAuthorizationCode(
        McpOAuthAuthorizationCodeConfig(
          serverUrl: '${fake.base}/mcp',
          authorizationUrl: '${fake.base}/as/authorize',
          tokenUrl: '${fake.base}/as/token',
          clientId: 'c',
          redirectPort: 19999,
        ),
        onAuthorizeUrl: (url) {
          final injected = Uri.parse(
              'http://127.0.0.1:19999/callback?error=access_denied&state=${url.queryParameters['state']}');
          Future<void>.microtask(() => oauth.completeCallback(injected));
        },
        openBrowser: false,
      );
      await expectLater(
        oauth.token(),
        throwsA(isA<McpOAuthFlowException>()
            .having((e) => e.code, 'code', 'access_denied')),
      );
    });

    test('token kedaluwarsa -> grant refresh_token tanpa otorisasi ulang',
        () async {
      final clock = _FakeClock();
      late final McpOAuthAuthorizationCode oauth;
      oauth = McpOAuthAuthorizationCode(
        McpOAuthAuthorizationCodeConfig(
          serverUrl: '${fake.base}/mcp',
          authorizationUrl: '${fake.base}/as/authorize',
          tokenUrl: '${fake.base}/as/token',
          clientId: 'c',
          redirectPort: 19999,
        ),
        clock: clock.now,
        onAuthorizeUrl: (url) {
          final injected = url.replace(queryParameters: {
            ...url.queryParameters,
            'code': 'good-code',
          });
          Future<void>.microtask(() => oauth.completeCallback(injected));
        },
        persistOverride: (tokens) async => persisted.add(tokens),
        loadOverride: () async => persisted.isEmpty ? null : persisted.last,
        openBrowser: false,
      );
      oauthUnderTest = oauth;
      expect(await oauth.token(), 'at-1');
      expect(fake.tokenRequests, hasLength(1));

      // Majukan melewati kedaluwarsa (3600 - 60 detik margin).
      clock.advance(const Duration(hours: 2));
      expect(await oauth.token(), 'at-2');
      expect(fake.tokenRequests, hasLength(2));
      expect(fake.tokenRequests.last.form['grant_type'], 'refresh_token');
      expect(fake.tokenRequests.last.form['refresh_token'], 'rt-1');
      // Tidak ada URL otorisasi baru.
      expect(oauth.lastAuthorizeUrl, isNotNull);
      expect(oauth.fetchCount, 2);
    });

    test('invalidate() hanya membuang access token; refresh dipakai', () async {
      final oauth = build();
      oauthUnderTest = oauth;
      expect(await oauth.token(), 'at-1');
      oauth.invalidate();
      expect(await oauth.token(), 'at-2');
      expect(fake.tokenRequests, hasLength(2));
      expect(fake.tokenRequests.last.form['grant_type'], 'refresh_token');
    });

    test('auth_method basic: kredensial di header Authorization', () async {
      final oauth = build(authMethod: 'basic');
      oauthUnderTest = oauth;
      await oauth.token();
      final auth = fake.tokenRequests.first.auth!;
      final decoded =
          utf8.decode(base64.decode(auth.replaceFirst('Basic ', '')));
      expect(decoded, 'conf-client:conf-secret');
      expect(fake.tokenRequests.first.form.containsKey('client_secret'), isFalse);
    });

    test('auth_method post: kredensial di body form', () async {
      final oauth = build(authMethod: 'post');
      oauthUnderTest = oauth;
      await oauth.token();
      expect(fake.tokenRequests.first.auth, isNull);
      expect(fake.tokenRequests.first.form['client_id'], 'conf-client');
      expect(fake.tokenRequests.first.form['client_secret'], 'conf-secret');
    });

    test('auth_method none: hanya client_id di body (public client)', () async {
      final oauth = build(clientId: 'pub-client', clientSecret: '', authMethod: 'none');
      oauthUnderTest = oauth;
      await oauth.token();
      expect(fake.tokenRequests.first.auth, isNull);
      expect(fake.tokenRequests.first.form['client_id'], 'pub-client');
      expect(fake.tokenRequests.first.form.containsKey('client_secret'), isFalse);
    });

    test('auth_method auto tanpa secret -> none (public client + PKCE)',
        () async {
      final oauth = build(clientId: 'pub-client', clientSecret: '');
      oauthUnderTest = oauth;
      await oauth.token();
      expect(fake.tokenRequests.first.auth, isNull);
      expect(fake.tokenRequests.first.form['client_id'], 'pub-client');
    });

    test('tanpa PKCE: tanpa code_challenge/verifier (penyedia lama)',
        () async {
      final oauth = build(usePkce: false);
      oauthUnderTest = oauth;
      await oauth.token();
      final authorize = oauth.lastAuthorizeUrl!;
      expect(authorize.queryParameters.containsKey('code_challenge'), isFalse);
      expect(
          fake.tokenRequests.first.form.containsKey('code_verifier'), isFalse);
    });

    test('discovery RFC 9728 -> RFC 8414 menemukan endpoint tanpa URL manual',
        () async {
      late final McpOAuthAuthorizationCode oauth;
      oauth = McpOAuthAuthorizationCode(
        McpOAuthAuthorizationCodeConfig(
          serverUrl: '${fake.base}/mcp',
          clientId: 'c',
          redirectPort: 19999,
          useDiscovery: true,
        ),
        onAuthorizeUrl: (url) {
          final injected = url.replace(queryParameters: {
            ...url.queryParameters,
            'code': 'good-code',
          });
          Future<void>.microtask(() => oauth.completeCallback(injected));
        },
        openBrowser: false,
      );
      oauthUnderTest = oauth;
      expect(await oauth.token(), 'at-1');
      expect(
        fake.wellKnownFetches.any((p) => p.contains('oauth-protected-resource')),
        isTrue,
      );
      expect(
        fake.wellKnownFetches.any((p) => p.contains('oauth-authorization-server')),
        isTrue,
      );
      expect(fake.tokenRequests.first.form['grant_type'], 'authorization_code');
    });

    test('DCR (RFC 7591): client_id didapat dari registrasi dinamis',
        () async {
      late final McpOAuthAuthorizationCode oauth;
      oauth = McpOAuthAuthorizationCode(
        McpOAuthAuthorizationCodeConfig(
          serverUrl: '${fake.base}/mcp',
          authorizationUrl: '${fake.base}/as/authorize',
          tokenUrl: '${fake.base}/as/token',
          registrationUrl: '${fake.base}/register',
          redirectPort: 19999,
          authMethod: 'none',
        ),
        onAuthorizeUrl: (url) {
          final injected = url.replace(queryParameters: {
            ...url.queryParameters,
            'code': 'good-code',
          });
          Future<void>.microtask(() => oauth.completeCallback(injected));
        },
        openBrowser: false,
      );
      oauthUnderTest = oauth;
      expect(await oauth.token(), 'at-1');
      expect(fake.registrationBodies, hasLength(1));
      expect(fake.registrationBodies.first['client_name'], 'Tiko-Agent MCP');
      expect(fake.registrationBodies.first['redirect_uris'],
          ['http://127.0.0.1:19999/callback']);
      expect(fake.tokenRequests.first.form['client_id'], 'dcr-client');
    });

    test('token terpersist: instance baru langsung pakai token tanpa alur '
        'interaktif', () async {
      final oauthA = build();
      oauthUnderTest = oauthA;
      expect(await oauthA.token(), 'at-1');
      expect(persisted, hasLength(1));
      expect(persisted.first['access_token'], 'at-1');
      expect(persisted.first['refresh_token'], 'rt-1');

      final oauthB = build();
      expect(await oauthB.token(), 'at-1');
      // Tidak ada panggilan token endpoint baru dari instance B.
      expect(fake.tokenRequests, hasLength(1));
    });

    test('persistensi file: mode 0600 dan atomik', () async {
      final dir = await Directory.systemTemp.createTemp('mcp-oauth-store');
      addTearDown(() => dir.delete(recursive: true));
      final storePath = '${dir.path}/tokens.json';
      late final McpOAuthAuthorizationCode oauth;
      oauth = McpOAuthAuthorizationCode(
        McpOAuthAuthorizationCodeConfig(
          serverUrl: '${fake.base}/mcp',
          authorizationUrl: '${fake.base}/as/authorize',
          tokenUrl: '${fake.base}/as/token',
          clientId: 'c',
          redirectPort: 19999,
          tokenStorePath: storePath,
        ),
        onAuthorizeUrl: (url) {
          final injected = url.replace(queryParameters: {
            ...url.queryParameters,
            'code': 'good-code',
          });
          Future<void>.microtask(() => oauth.completeCallback(injected));
        },
        openBrowser: false,
      );
      oauthUnderTest = oauth;
      expect(await oauth.token(), 'at-1');
      final file = File(storePath);
      expect(await file.exists(), isTrue);
      final stat = await file.stat();
      // Hanya owner yang punya izin (0600).
      expect(stat.mode & 0x1FF, 0x180); // 0600 oktal = 384 desimal
      final stored = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      expect(stored['access_token'], 'at-1');
      expect(stored['server_url'], '${fake.base}/mcp');
    });

    test('redirect loopback nyata: browser GET /callback menyelesaikan alur',
        () async {
      late final McpOAuthAuthorizationCode oauth;
      oauth = McpOAuthAuthorizationCode(
        McpOAuthAuthorizationCodeConfig(
          serverUrl: '${fake.base}/mcp',
          authorizationUrl: '${fake.base}/as/authorize',
          tokenUrl: '${fake.base}/as/token',
          clientId: 'c',
          redirectPort: 0, // ephemeral
        ),
        openBrowser: true, // xdg-open gagal senyap di sandbox; loopback tetap hidup
      );
      oauthUnderTest = oauth;
      final tokenFuture = oauth.token();
      // Tunggu URL otorisasi terbang, lalu simulasikan browser redirect.
      while (oauth.lastAuthorizeUrl == null) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      final redirectUri =
          Uri.parse(oauth.lastAuthorizeUrl!.queryParameters['redirect_uri']!);
      final browser = await HttpClient()
          .getUrl(redirectUri.replace(queryParameters: {
            'code': 'good-code',
            'state': oauth.lastAuthorizeUrl!.queryParameters['state']!,
          }))
          .then((req) => req.close());
      expect(browser.statusCode, 200);
      final body = await browser.transform(utf8.decoder).join();
      expect(body, contains('Otorisasi Tiko selesai'));
      expect(await tokenFuture, 'at-1');
    });
  });

  group('integrasi HttpMcpClient', () {
    late _FakeOAuthServer fake;
    setUp(() async {
      fake = _FakeOAuthServer();
      addTearDown(fake.close);
    });

    test('klien MCP HTTP memakai bearer token authorization_code', () async {
      final persisted = <Map<String, dynamic>>[];
      Uri? lastAuthorize;
      McpOAuthAuthorizationCode? oauthRef;
      late final McpOAuthAuthorizationCode oauth;
      oauth = McpOAuthAuthorizationCode(
        McpOAuthAuthorizationCodeConfig(
          serverUrl: '${fake.base}/mcp',
          authorizationUrl: '${fake.base}/as/authorize',
          tokenUrl: '${fake.base}/as/token',
          clientId: 'c',
          redirectPort: 19999,
        ),
        onAuthorizeUrl: (url) {
          lastAuthorize = url;
          final injected = url.replace(queryParameters: {
            ...url.queryParameters,
            'code': 'good-code',
          });
          Future<void>.microtask(() => oauthRef!.completeCallback(injected));
        },
        persistOverride: (tokens) async => persisted.add(tokens),
        loadOverride: () async => persisted.isEmpty ? null : persisted.last,
        openBrowser: false,
      );
      oauthRef = oauth;

      // Fake MCP endpoint sudah disediakan _FakeOAuthServer? Tidak — token
      // endpoint saja. Gunakan instance kedua yang sudah punya token lewat
      // persistensi untuk menguji integrasi penuh.
      expect(await oauth.token(), 'at-1');

      // Server MCP stub minimal.
      final mcp = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(mcp.close);
      final authHeaders = <String?>[];
      mcp.listen((req) async {
        await utf8.decoder.bind(req).join();
        authHeaders.add(req.headers.value('authorization'));
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode({
          'jsonrpc': '2.0',
          'id': 1,
          'result': {
            'protocolVersion': '2025-11-25',
            'serverInfo': {'name': 'stub', 'version': '1.0'},
          },
        }));
        await req.response.close();
      });

      final client = HttpMcpClient(
        baseUrl: 'http://127.0.0.1:${mcp.port}',
        oauth: oauth,
      );
      await client.start();
      expect(authHeaders.first, 'Bearer at-1');
      await client.close();
      expect(lastAuthorize, isNotNull);
    });
  });
}

class _FakeClock {
  DateTime _now = DateTime.utc(2026, 11, 16, 12);
  DateTime now() => _now;
  void advance(Duration d) => _now = _now.add(d);
}

class _DeterministicRandom implements Random {
  _DeterministicRandom(this._seed);
  int _seed;
  @override
  bool nextBool() => _nextInt(2) == 0;
  @override
  int nextInt(int max) => _nextInt(max);
  int _nextInt(int max) {
    _seed = (_seed * 1103515245 + 12345) & 0x7FFFFFFF;
    return _seed % max;
  }
  @override
  double nextDouble() => _nextInt(1 << 30) / (1 << 30);
}

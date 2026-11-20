import 'dart:convert';
import 'dart:io';

import 'package:agent_tools/agent_tools.dart';
import 'package:test/test.dart';

class _OAuthFixture {
  late final HttpServer server;
  late final String base;
  final tokenFetches = <Map<String, dynamic>>[];
  final mcpRequests = <({String? auth, Map<String, dynamic> body})>[];
  var mcpUnauthorizedOnce = false;
  var force401 = false;

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = 'http://127.0.0.1:${server.port}';
    server.listen((req) async {
      final body = await utf8.decoder.bind(req).join();
      if (req.uri.path == '/token') {
        tokenFetches.add(Uri.splitQueryString(body));
        final encoded = (req.headers.value('authorization') ?? '').replaceFirst(
          'Basic ',
          '',
        );
        final decoded = utf8.decode(base64.decode(encoded));
        req.response.headers.contentType = ContentType.json;
        if (decoded != 'tiko-client:tiko-secret') {
          req.response.statusCode = 401;
          req.response.write('bad credentials');
          await req.response.close();
          return;
        }
        req.response.write(
          jsonEncode({
            'access_token': 'tok-${tokenFetches.length}',
            'token_type': 'Bearer',
            'expires_in': 3600,
          }),
        );
        await req.response.close();
        return;
      }
      if (req.method == 'GET') {
        req.response.statusCode = 404;
        await req.response.close();
        return;
      }
      final auth = req.headers.value('authorization');
      final rpc = jsonDecode(body) as Map<String, dynamic>;
      mcpRequests.add((auth: auth, body: rpc));
      req.response.headers.contentType = ContentType.json;
      if (force401 && !mcpUnauthorizedOnce) {
        mcpUnauthorizedOnce = true;
        req.response.statusCode = 401;
        req.response.write(jsonEncode({'error': 'invalid token'}));
        await req.response.close();
        return;
      }
      final id = rpc['id'];
      final method = rpc['method']?.toString() ?? '';
      req.response.write(
        jsonEncode({
          'jsonrpc': '2.0',
          'id': id,
          'result': method == 'tools/list'
              ? {
                  'tools': [
                    {
                      'name': 'stub_tool',
                      'description': 'stub',
                      'inputSchema': {'type': 'object'},
                    },
                  ],
                }
              : {
                  'protocolVersion': '2025-11-25',
                  'serverInfo': {'name': 'stub', 'version': '1.0'},
                },
        }),
      );
      await req.response.close();
    });
  }

  Future<void> close() => server.close(force: true);

  McpOAuthClientCredentials buildOauth() => McpOAuthClientCredentials(
    McpOAuthConfig(
      tokenUrl: '$base/token',
      clientId: 'tiko-client',
      clientSecret: 'tiko-secret',
      scopes: ['mcp:read'],
    ),
  );
}

void main() {
  Future<_OAuthFixture> fixture() async {
    final value = _OAuthFixture();
    await value.start();
    addTearDown(value.close);
    return value;
  }

  test('oauth: token diambil dan Authorization Bearer terkirim', () async {
    final testFixture = await fixture();
    final client = HttpMcpClient(
      baseUrl: testFixture.base,
      oauth: testFixture.buildOauth(),
    );
    await client.start();
    expect(client.serverName, 'stub');
    expect(testFixture.tokenFetches, hasLength(1));
    expect(testFixture.tokenFetches.first['grant_type'], 'client_credentials');
    expect(testFixture.tokenFetches.first['scope'], 'mcp:read');
    expect(testFixture.mcpRequests.first.auth, 'Bearer tok-1');
    await client.close();
  });

  test('oauth: token di-cache antar request', () async {
    final testFixture = await fixture();
    final client = HttpMcpClient(
      baseUrl: testFixture.base,
      oauth: testFixture.buildOauth(),
    );
    await client.start();
    final afterStart = testFixture.tokenFetches.length;
    await client.listTools();
    await client.listTools();
    expect(testFixture.tokenFetches.length, afterStart);
    await client.close();
  });

  test('oauth: concurrent token requests share one fetch', () async {
    final testFixture = await fixture();
    final oauth = testFixture.buildOauth();
    final tokens = await Future.wait([oauth.token(), oauth.token()]);
    expect(tokens, ['tok-1', 'tok-1']);
    expect(testFixture.tokenFetches, hasLength(1));
    expect(oauth.fetchCount, 1);
  });

  test('oauth: 401 -> refresh sekali lalu replay', () async {
    final testFixture = await fixture();
    testFixture.force401 = true;
    final client = HttpMcpClient(
      baseUrl: testFixture.base,
      oauth: testFixture.buildOauth(),
    );
    await client.start();
    expect(testFixture.tokenFetches, hasLength(2));
    await client.listTools();
    expect(testFixture.tokenFetches, hasLength(2));
    expect(client.transportErrors.any((e) => '$e'.contains('401')), isTrue);
    await client.close();
  });

  test('oauth config: token URL tidak aman ditolak', () {
    expect(
      () => McpOAuthConfig(
        tokenUrl: 'ftp://x/token',
        clientId: 'c',
        clientSecret: 's',
      ),
      throwsArgumentError,
    );
    expect(
      () => McpOAuthConfig(
        tokenUrl: 'http://127.0.0.1/t',
        clientId: '',
        clientSecret: 's',
      ),
      throwsArgumentError,
    );
  });
}

import 'dart:convert';
import 'dart:io';

import 'package:agent_tools/agent_tools.dart';
import 'package:test/test.dart';

void main() {
  late HttpServer server;
  late String base;
  final tokenFetches = <Map<String, dynamic>>[];
  final mcpRequests = <({String? auth, Map<String, dynamic> body})>[];
  var mcpUnauthorizedOnce = false;
  var force401 = false;

  setUp(() async {
    tokenFetches.clear();
    mcpRequests.clear();
    mcpUnauthorizedOnce = false;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = 'http://127.0.0.1:${server.port}';
    server.listen((req) async {
      final body = await utf8.decoder.bind(req).join();
      if (req.uri.path == '/token') {
        tokenFetches.add(Uri.splitQueryString(body));
        final authHeader = req.headers.value('authorization') ?? '';
        final encoded = authHeader.replaceFirst('Basic ', '');
        final decoded = utf8.decode(base64.decode(encoded));
        req.response.headers.contentType = ContentType.json;
        if (decoded != 'tiko-client:tiko-secret') {
          req.response.statusCode = 401;
          req.response.write('bad credentials');
          await req.response.close();
          return;
        }
        req.response.write(jsonEncode({
          'access_token': 'tok-${tokenFetches.length}',
          'token_type': 'Bearer',
          'expires_in': 3600,
        }));
        await req.response.close();
        return;
      }
      // Optional GET SSE stream: not offered by this stub.
      if (req.method == 'GET') {
        req.response.statusCode = 404;
        await req.response.close();
        return;
      }
      // MCP endpoint
      final auth = req.headers.value('authorization');
      mcpRequests.add((auth: auth, body: jsonDecode(body) as Map<String, dynamic>));
      req.response.headers.contentType = ContentType.json;
      if (force401 && !mcpUnauthorizedOnce) {
        mcpUnauthorizedOnce = true;
        req.response.statusCode = 401;
        req.response.write(jsonEncode({'error': 'invalid token'}));
        await req.response.close();
        return;
      }
      final rpc = jsonDecode(body) as Map<String, dynamic>;
      final id = rpc['id'];
      final method = rpc['method']?.toString() ?? '';
      if (method == 'tools/list') {
        req.response.write(jsonEncode({
          'jsonrpc': '2.0',
          'id': id,
          'result': {
            'tools': [
              {
                'name': 'stub_tool',
                'description': 'stub',
                'inputSchema': {'type': 'object'},
              },
            ],
          },
        }));
      } else {
        req.response.write(jsonEncode({
          'jsonrpc': '2.0',
          'id': id,
          'result': {
            'protocolVersion': '2025-11-25',
            'serverInfo': {'name': 'stub', 'version': '1.0'},
          },
        }));
      }
      await req.response.close();
    });
    addTearDown(() => server.close(force: true));
  });

  McpOAuthClientCredentials buildOauth() => McpOAuthClientCredentials(
        McpOAuthConfig(
          tokenUrl: '$base/token',
          clientId: 'tiko-client',
          clientSecret: 'tiko-secret',
          scopes: ['mcp:read'],
        ),
      );

  test('oauth: token diambil dan Authorization Bearer terkirim', () async {
    final client = HttpMcpClient(
      baseUrl: base,
      oauth: buildOauth(),
    );
    await client.start();
    expect(client.serverName, 'stub');
    expect(tokenFetches, hasLength(1));
    expect(tokenFetches.first['grant_type'], 'client_credentials');
    expect(tokenFetches.first['scope'], 'mcp:read');
    expect(mcpRequests.first.auth, 'Bearer tok-1');
    await client.close();
  });

  test('oauth: token di-cache antar request', () async {
    final client = HttpMcpClient(baseUrl: base, oauth: buildOauth());
    await client.start();
    final afterStart = tokenFetches.length;
    await client.listTools();
    await client.listTools();
    expect(tokenFetches.length, afterStart);
    await client.close();
  });

  test('oauth: 401 -> refresh sekali lalu replay', () async {
    force401 = true;
    final client = HttpMcpClient(baseUrl: base, oauth: buildOauth());
    await client.start();
    expect(tokenFetches, hasLength(2));
    await client.listTools();
    expect(tokenFetches, hasLength(2));
    expect(
      client.transportErrors.any((e) => '$e'.contains('401')),
      isTrue,
    );
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

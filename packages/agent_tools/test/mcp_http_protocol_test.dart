import 'dart:convert';
import 'dart:io';

import 'package:agent_tools/agent_tools.dart';
import 'package:test/test.dart';

/// Fake MCP HTTP server untuk test interop negosiasi versi protokol.
///
/// [modernBehavior] menentukan respons initialize ketika client meminta
/// versi modern (2026-07-28):
/// - accept: meng-echo versi yang diminta (server modern penuh);
/// - downgrade: sukses dengan versi lama (server spec-compliant lama);
/// - reject: JSON-RPC error (server menolak versi asing);
/// - http400: HTTP 400 tanpa body JSON-RPC;
/// - rejectAll: HTTP 400 untuk versi berapa pun.
void main() {
  late HttpServer server;
  late String baseUrl;
  _ModernBehavior modernBehavior = _ModernBehavior.accept;
  var initializeAttempts = 0;
  String? lastProtocolVersionHeader;

  Future<void> handle(HttpRequest req) async {
    if (req.method == 'GET') {
      req.response.statusCode = 405;
      await req.response.close();
      return;
    }
    lastProtocolVersionHeader = req.headers.value('mcp-protocol-version');
    final body = await utf8.decoder.bind(req).join();
    final msg = body.isEmpty
        ? const <String, dynamic>{}
        : jsonDecode(body) as Map<String, dynamic>;
    final method = msg['method'] as String?;
    if (method == 'initialize') {
      initializeAttempts++;
      final requested = msg['params']['protocolVersion'] as String?;
      if (modernBehavior == _ModernBehavior.rejectAll) {
        req.response.statusCode = 400;
        req.response.headers.contentType = ContentType.json;
        req.response.write(
          jsonEncode({
            'jsonrpc': '2.0',
            'id': msg['id'],
            'error': {'code': -32602, 'message': 'bad version'},
          }),
        );
        await req.response.close();
        return;
      }
      if (requested == '2026-07-28') {
        switch (modernBehavior) {
          case _ModernBehavior.accept:
            await _respondJson(req, {
              'jsonrpc': '2.0',
              'id': msg['id'],
              'result': {
                'protocolVersion': '2026-07-28',
                'serverInfo': {'name': 'mock-modern'},
              },
            });
            return;
          case _ModernBehavior.downgrade:
            await _respondJson(req, {
              'jsonrpc': '2.0',
              'id': msg['id'],
              'result': {
                'protocolVersion': '2025-11-25',
                'serverInfo': {'name': 'mock-legacy'},
              },
            });
            return;
          case _ModernBehavior.reject:
            await _respondJson(req, {
              'jsonrpc': '2.0',
              'id': msg['id'],
              'error': {
                'code': -32602,
                'message': 'Unsupported protocol version',
              },
            });
            return;
          case _ModernBehavior.http400:
            req.response.statusCode = 400;
            req.response.headers.contentType = ContentType.json;
            req.response.write(
              jsonEncode({
                'jsonrpc': '2.0',
                'id': msg['id'],
                'error': {'code': -32602, 'message': 'bad version'},
              }),
            );
            await req.response.close();
            return;
          case _ModernBehavior.rejectAll:
            throw StateError('unreachable: rejectAll ditangani lebih awal');
        }
      }
      await _respondJson(req, {
        'jsonrpc': '2.0',
        'id': msg['id'],
        'result': {
          'protocolVersion': requested,
          'serverInfo': {'name': 'mock-legacy'},
        },
      });
      return;
    }
    if (method == 'notifications/initialized') {
      req.response.statusCode = 202;
      await req.response.close();
      return;
    }
    if (method == 'tools/list') {
      await _respondJson(req, {
        'jsonrpc': '2.0',
        'id': msg['id'],
        'result': {
          'tools': [
            {
              'name': 'echo',
              'description': 'gema',
              'inputSchema': {'type': 'object'},
            },
          ],
        },
      });
      return;
    }
    if (method == 'ping') {
      await _respondJson(req, {
        'jsonrpc': '2.0',
        'id': msg['id'],
        'result': {'ok': true},
      });
      return;
    }
    req.response.statusCode = 404;
    await req.response.close();
  }

  setUp(() async {
    modernBehavior = _ModernBehavior.accept;
    initializeAttempts = 0;
    lastProtocolVersionHeader = null;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    baseUrl = 'http://127.0.0.1:${server.port}/mcp';
    server.listen(handle);
  });

  tearDown(() async {
    await server.close();
  });

  test('server modern menerima 2026-07-28 dan versi itu dipakai di header', () async {
    final c = HttpMcpClient(baseUrl: baseUrl);
    addTearDown(c.close);
    await c.start();
    expect(initializeAttempts, 1);
    expect(c.negotiatedProtocolVersion, '2026-07-28');
    expect(c.serverName, 'mock-modern');
    await c.request('ping');
    expect(lastProtocolVersionHeader, '2026-07-28');
  });

  test('server lama menurunkan versi lewat hasil initialize tanpa fallback',
      () async {
    modernBehavior = _ModernBehavior.downgrade;
    final c = HttpMcpClient(baseUrl: baseUrl);
    addTearDown(c.close);
    await c.start();
    expect(initializeAttempts, 1);
    expect(c.negotiatedProtocolVersion, '2025-11-25');
    expect(c.serverName, 'mock-legacy');
  });

  test('server yang menolak versi modern dengan RPC error memicu fallback',
      () async {
    modernBehavior = _ModernBehavior.reject;
    final c = HttpMcpClient(baseUrl: baseUrl);
    addTearDown(c.close);
    await c.start();
    expect(initializeAttempts, 2);
    expect(c.negotiatedProtocolVersion, '2025-11-25');
    final tools = await c.listTools();
    expect(tools.single.name, 'echo');
  });

  test('penolakan lewat HTTP 400 juga memicu fallback ke versi baseline',
      () async {
    modernBehavior = _ModernBehavior.http400;
    final c = HttpMcpClient(baseUrl: baseUrl);
    addTearDown(c.close);
    await c.start();
    expect(initializeAttempts, 2);
    expect(c.negotiatedProtocolVersion, '2025-11-25');
  });

  test('konfigurasi eksplisit modern == baseline tidak memicu fallback',
      () async {
    modernBehavior = _ModernBehavior.rejectAll;
    final c = HttpMcpClient(
      baseUrl: baseUrl,
      protocolVersion: '2025-11-25',
      preferredModernProtocolVersion: '2025-11-25',
    );
    addTearDown(c.close);
    await expectLater(c.start(), throwsA(isA<StateError>()));
    expect(initializeAttempts, 1);
  });

  test('preferredModernProtocolVersion divalidasi format YYYY-MM-DD', () {
    expect(
      () => HttpMcpClient(baseUrl: baseUrl, preferredModernProtocolVersion: 'x'),
      throwsArgumentError,
    );
  });
}

enum _ModernBehavior { accept, downgrade, reject, http400, rejectAll }

Future<void> _respondJson(HttpRequest req, Map<String, dynamic> body) async {
  req.response.headers.contentType = ContentType.json;
  req.response.write(jsonEncode(body));
  await req.response.close();
}

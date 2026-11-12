import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_tools/agent_tools.dart';
import 'package:test/test.dart';

void main() {
  group('P1-9 MCP HTTP resilience', () {
    test('404 session expiry: re-initialize and replay the request once',
        () async {
      var initializeCount = 0;
      var expired = false;
      var toolCallCount = 0;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async {
        await server.close(force: true);
      });
      server.listen((req) async {
        if (req.method == 'GET') {
          req.response.statusCode = 405;
          await req.response.close();
          return;
        }
        if (req.method == 'DELETE') {
          req.response.statusCode = 200;
          await req.response.close();
          return;
        }
        final body = await utf8.decoder.bind(req).join();
        final msg = jsonDecode(body) as Map<String, dynamic>;
        final method = msg['method'] as String?;
        if (method == 'initialize') {
          initializeCount++;
          req.response.headers.set(
              'mcp-session-id', initializeCount == 1 ? 'sess-1' : 'sess-2');
          req.response.headers.contentType = ContentType.json;
          req.response.write(jsonEncode({
            'jsonrpc': '2.0',
            'id': msg['id'],
            'result': {
              'protocolVersion': msg['params']['protocolVersion'],
              'serverInfo': {'name': 'mock-restart'},
            },
          }));
          await req.response.close();
          return;
        }
        if (method == 'notifications/initialized') {
          req.response.statusCode = 202;
          await req.response.close();
          return;
        }
        if (expired &&
            (req.headers.value('mcp-session-id') ?? '') == 'sess-1') {
          req.response.statusCode = 404;
          await req.response.close();
          return;
        }
        if (method == 'tools/call') {
          toolCallCount++;
          req.response.headers.contentType = ContentType.json;
          req.response.write(jsonEncode({
            'jsonrpc': '2.0',
            'id': msg['id'],
            'result': {
              'content': [
                {'type': 'text', 'text': 'hasil setelah recovery'},
              ],
              'isError': false,
            },
          }));
          await req.response.close();
          return;
        }
        req.response.statusCode = 404;
        await req.response.close();
      });

      final c = HttpMcpClient(baseUrl: 'http://127.0.0.1:${server.port}/mcp');
      addTearDown(c.close);
      await c.start();
      expect(c.sessionId, 'sess-1');

      expired = true;
      final out = await c.callTool('echo', {'x': 1});
      expect(out, contains('hasil setelah recovery'));
      expect(initializeCount, 2, reason: 'client harus re-initialize sekali');
      expect(toolCallCount, 1,
          reason: 'tools/call direplay ke session baru, tidak dobel');
      expect(c.sessionId, 'sess-2');
      expect(
        c.transportErrors.any((e) => '$e'.contains('session expired')),
        isTrue,
      );
    });

    test('SSE stream diputus server: client reconnect dan terima notifikasi',
        () async {
      var streamCount = 0;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async {
        await server.close(force: true);
      });
      server.listen((req) async {
        if (req.method != 'GET') {
          // Minimal JSON-RPC answers so start() succeeds.
          final body = await utf8.decoder.bind(req).join();
          final msg = body.isEmpty
              ? <String, dynamic>{}
              : jsonDecode(body) as Map<String, dynamic>;
          final method = msg['method'] as String?;
          if (method == 'initialize') {
            req.response.headers.set('mcp-session-id', 'sess-sse');
            req.response.headers.contentType = ContentType.json;
            req.response.write(jsonEncode({
              'jsonrpc': '2.0',
              'id': msg['id'],
              'result': {
                'protocolVersion': msg['params']['protocolVersion'],
                'serverInfo': {'name': 'mock-sse'},
              },
            }));
          } else {
            req.response.statusCode = 202;
          }
          await req.response.close();
          return;
        }
        streamCount++;
        if (streamCount <= 2) {
          req.response.headers.contentType =
              ContentType('text', 'event-stream');
          req.response.write(
            'data: ${jsonEncode({
              'jsonrpc': '2.0',
              'method': 'notifications/round-$streamCount',
            })}\n\n',
          );
          await req.response.close();
          return;
        }
        req.response.statusCode = 405;
        await req.response.close();
      });

      final c = HttpMcpClient(baseUrl: 'http://127.0.0.1:${server.port}/mcp');
      addTearDown(c.close);
      await c.start();

      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (streamCount < 3 && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
      expect(streamCount, 3,
          reason: 'dua koneksi SSE dengan notifikasi, lalu berhenti di 405');
      final methods = c.notifications.map((n) => n['method']).toList();
      expect(methods, contains('notifications/round-1'));
      expect(methods, contains('notifications/round-2'));
      final reconnected = c.transportErrors
          .where((e) => '$e'.contains('stream closed by server'))
          .length;
      expect(reconnected, greaterThanOrEqualTo(1));
    });
  });
}

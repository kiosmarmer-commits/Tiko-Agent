import 'dart:async';
import 'dart:convert';
import 'dart:io';


import 'package:agent_tools/agent_tools.dart';
import 'package:test/test.dart';

/// Mock MCP server yang mengirim server-initiated `sampling/createMessage`
/// melalui GET SSE dan menerima response JSON-RPC via POST (P1-7).
class _SamplingServer {
  _SamplingServer({this.samplingRequests = 1});

  final int samplingRequests;

  late HttpServer server;
  late String baseUrl;
  final responses = <Map<String, dynamic>>[];
  final _responseReceived = StreamController<void>.broadcast();
  HttpResponse? _sseResponse;

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    baseUrl = 'http://127.0.0.1:${server.port}';
    server.listen((req) async {
      if (req.method == 'GET') {
        req.response.bufferOutput = false;
        req.response.headers.contentType =
            ContentType('text', 'event-stream');
        _sseResponse = req.response;
        // Delay kecil agar handler subscription siap sebelum event dikirim.
        await Future<void>.delayed(const Duration(milliseconds: 500));
        for (var i = 0; i < samplingRequests; i++) {
          req.response.write(
            'data: ${jsonEncode({
              'jsonrpc': '2.0',
              'id': 'srv-$i',
              'method': 'sampling/createMessage',
              'params': {
                'messages': [
                  {
                    'role': 'user',
                    'content': {'type': 'text', 'text': 'ringkas berita'},
                  },
                ],
                'maxTokens': 64,
              },
            })}\n\n',
          );
        }
        await req.response.flush();
        return;
      }
      final body = await utf8.decodeStream(req);
      final msg = body.isEmpty
          ? const <String, dynamic>{}
          : jsonDecode(body) as Map<String, dynamic>;
      final method = msg['method'] as String?;
      if (method == 'initialize') {
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode({
          'jsonrpc': '2.0',
          'id': msg['id'],
          'result': {
            'protocolVersion': msg['params']['protocolVersion'],
            'serverInfo': {'name': 'mock-sampling'},
          },
        }));
        await req.response.close();
        return;
      }
      if (method == null && msg.containsKey('id')) {
        responses.add(msg);
        _responseReceived.add(null);
        req.response.statusCode = 202;
        await req.response.close();
        return;
      }
      req.response.statusCode = 202;
      await req.response.close();
    });
  }

  Future<void> waitResponses(int count) async {
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (responses.length < count && DateTime.now().isBefore(deadline)) {
      await _responseReceived.stream.first
          .timeout(const Duration(seconds: 2), onTimeout: () {});
    }
  }

  Future<void> close() async {
    try {
      await _sseResponse?.close();
    } catch (_) {}
    await server.close(force: true);
    await _responseReceived.close();
  }
}

void main() {
  test('sampling/createMessage dijawab via onSampling dan di-POST balik',
      () async {
    final srv = _SamplingServer();
    await srv.start();
    final client = EnhancedHttpMcpClient(
      baseUrl: srv.baseUrl,
      toolRegistry: ToolRegistry(),
      onSampling: (params, requestId) async => {
        'role': 'assistant',
        'content': {
          'type': 'text',
          'text': 'ringkasan: model menjawab $requestId',
        },
        'model': 'mock-model',
      },
    );
    await client.start();
    await srv.waitResponses(1);

    expect(srv.responses, hasLength(1));
    final resp = srv.responses.single;
    expect(resp['jsonrpc'], '2.0');
    expect(resp['id'], 'srv-0');
    expect(resp['result']['role'], 'assistant');
    expect(
      (resp['result']['content'] as Map)['text'],
      contains('model menjawab srv-0'),
    );
    await client.close();
    await srv.close();
  });

  test('sampling tanpa callback ditolak dengan error -32601', () async {
    final srv = _SamplingServer(samplingRequests: 2);
    await srv.start();
    final client = EnhancedHttpMcpClient(
      baseUrl: srv.baseUrl,
      toolRegistry: ToolRegistry(),
    );
    await client.start();
    await srv.waitResponses(2);

    expect(srv.responses, hasLength(2));
    for (final resp in srv.responses) {
      expect(resp['error']['code'], -32601);
      expect(resp['error']['message'], contains('not supported'));
    }
    await client.close();
    await srv.close();
  });

  test('sampling melebihi rate limit ditolak dengan error -32005', () async {
    final srv = _SamplingServer(samplingRequests: 3);
    await srv.start();
    final client = EnhancedHttpMcpClient(
      baseUrl: srv.baseUrl,
      toolRegistry: ToolRegistry(),
      onSampling: (params, requestId) async => {
        'role': 'assistant',
        'content': {'type': 'text', 'text': 'ok'},
      },
      maxSamplingPerMinute: 2,
    );
    await client.start();
    await srv.waitResponses(3);

    expect(srv.responses, hasLength(3));
    final ok = srv.responses
        .where((r) => r.containsKey('result'))
        .map((r) => r['id'])
        .toSet();
    final limited = srv.responses
        .where((r) => r.containsKey('error'))
        .map((r) => r['id'])
        .toSet();
    expect(ok, hasLength(2));
    expect(limited, {'srv-2'});
    expect(
      srv.responses
          .firstWhere((r) => r['id'] == 'srv-2')['error']['code'],
      -32005,
    );
    await client.close();
    await srv.close();
  });
}

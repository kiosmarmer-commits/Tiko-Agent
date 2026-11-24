import 'dart:convert';
import 'dart:io';

import 'package:agent_gateway/agent_gateway.dart';
import 'package:test/test.dart';

/// Hermes S7: publish/share + download artifact —
/// POST /v1/artifacts/publish, GET /v1/artifacts/download;
/// validasi path 400, 501 bare daemon, unduh byte mentah.
void main() {
  late HttpApiServer server;
  late HttpApiServer bare;
  late String? lastPublishPath;
  late String? lastPublishSession;

  setUp(() async {
    lastPublishPath = null;
    lastPublishSession = null;
    server = HttpApiServer(
      onMessage: (_) async => 'ok',
      authToken: 'manager-token-0123456789abcdef',
      port: 0,
      artifactsPublishProvider: (body) async {
        lastPublishPath = '${body['path'] ?? ''}';
        lastPublishSession = '${body['session_id'] ?? ''}';
        return {
          'published_path': '.tiko/published/laporan-123.md',
          'bytes': 12,
          'source': 'laporan.md',
          'share_text': 'Artifact "laporan.md" sudah dipublikasikan',
        };
      },
      artifactsDownloadProvider: (path) async {
        if (path == 'hantu.bin') {
          throw ApiRequestException(404, 'not_found', 'file tidak ditemukan');
        }
        return {'filename': 'data.bin', 'bytes': [1, 2, 3, 4, 5], 'bytes_size': 5};
      },
    );
    await server.start();
    bare = HttpApiServer(
      onMessage: (_) async => 'ok',
      authToken: 'manager-token-0123456789abcdef',
      port: 0,
    );
    await bare.start();
  });

  tearDown(() async {
    await server.stop();
    await bare.stop();
  });

  Future<(int, Map<String, dynamic>, String)> send(
    String method,
    String path, {
    Object? body,
    HttpApiServer? target,
  }) async {
    final client = HttpClient();
    try {
      final uri = Uri.parse('http://127.0.0.1:${(target ?? server).boundPort}$path');
      final request = await client.openUrl(method, uri);
      request.headers.set('content-type', 'application/json');
      request.headers
          .set('authorization', 'Bearer manager-token-0123456789abcdef');
      if (body != null) request.add(utf8.encode(jsonEncode(body)));
      final response = await request.close();
      final text = await response.transform(utf8.decoder).join();
      final decoded = text.isEmpty
          ? <String, dynamic>{}
          : jsonDecode(text) as Map<String, dynamic>;
      return (response.statusCode, decoded, text);
    } finally {
      client.close(force: true);
    }
  }

  test('POST /v1/artifacts/publish meneruskan path + session_id', () async {
    final (status, body, _) = await send(
      'POST',
      '/v1/artifacts/publish',
      body: {'path': 'laporan.md', 'session_id': 's1'},
    );
    expect(status, 200);
    expect(lastPublishPath, 'laporan.md');
    expect(lastPublishSession, 's1');
    expect(body['published_path'], '.tiko/published/laporan-123.md');
    expect(body['share_text'], isNotEmpty);
  });

  test('POST publish path kosong \u2192 400', () async {
    final (status, body, _) =
        await send('POST', '/v1/artifacts/publish', body: {'path': ''});
    expect(status, 400);
    expect(body['code'], isNotEmpty);
  });

  test('GET /v1/artifacts/download mengembalikan byte mentah + header', () async {
    final client = HttpClient();
    try {
      final uri = Uri.parse(
          'http://127.0.0.1:${server.boundPort}/v1/artifacts/download?path=data.bin');
      final request = await client.openUrl('GET', uri);
      request.headers
          .set('authorization', 'Bearer manager-token-0123456789abcdef');
      final response = await request.close();
      final bytes = <int>[];
      await for (final chunk in response) {
        bytes.addAll(chunk);
      }
      expect(response.statusCode, 200);
      expect(bytes, [1, 2, 3, 4, 5]);
      expect(response.headers.value('content-type'), 'application/octet-stream');
      expect(response.headers.value('x-artifact-bytes'), '5');
      expect(response.headers.value('content-disposition'), contains('data.bin'));
    } finally {
      client.close(force: true);
    }
  });

  test('download file tidak dikenal \u2192 404, path kosong \u2192 400', () async {
    final (status404, body404, _) = await send(
        'GET', '/v1/artifacts/download?path=hantu.bin');
    expect(status404, 404);
    expect(body404['code'], 'not_found');

    final (status400, _, _) =
        await send('GET', '/v1/artifacts/download');
    expect(status400, 400);
  });

  test('501 bare daemon untuk publish + download', () async {
    final (pubStatus, pubBody, _) = await send('POST',
        '/v1/artifacts/publish', target: bare,
        body: {'path': 'a.md'});
    expect(pubStatus, 501);
    expect(pubBody['code'], 'not_implemented');
    final (dlStatus, _, _) = await send(
        'GET', '/v1/artifacts/download?path=a.md', target: bare);
    expect(dlStatus, 501);
  });
}

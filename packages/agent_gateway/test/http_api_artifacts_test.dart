import 'dart:convert';
import 'dart:io';

import 'package:agent_gateway/agent_gateway.dart';
import 'package:test/test.dart';

/// GUI-P2-04: artifacts browser read-only — GET /v1/artifacts
/// (list dir), /v1/artifacts/read, /v1/artifacts/diff; query path wajib,
/// validasi 400, 501 bare daemon.
void main() {
  late HttpApiServer server;
  late HttpApiServer bare;
  late String? lastListDir;
  late String? lastReadPath;
  late String? lastDiffPath;

  setUp(() async {
    lastListDir = null;
    lastReadPath = null;
    lastDiffPath = null;
    server = HttpApiServer(
      onMessage: (_) async => 'ok',
      authToken: 'manager-token-0123456789abcdef',
      port: 0,
      artifactsListProvider: (dir) async {
        lastListDir = dir;
        return {
          'files': [
            {'path': 'README.md', 'bytes': 6, 'modified': '2026-11-18T13:00:00.000Z'},
          ],
          'truncated': false,
        };
      },
      artifactsReadProvider: (path) async {
        lastReadPath = path;
        return {
          'path': path,
          'bytes': 6,
          'binary': false,
          'truncated': false,
          'content': 'halo\n',
          'bak_exists': true,
        };
      },
      artifactsDiffProvider: (path) async {
        lastDiffPath = path;
        return {
          'path': path,
          'old_exists': true,
          'new_exists': true,
          'lines': [
            {'type': '=', 'text': 'keep'},
            {'type': '-', 'text': 'lama'},
            {'type': '+', 'text': 'baru'},
          ],
          'truncated': false,
        };
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

  Future<Map<String, dynamic>> send(String method, String path,
      HttpApiServer target) async {
    final client = HttpClient();
    try {
      final uri = Uri.parse('http://127.0.0.1:${target.boundPort}$path');
      final request = await client.openUrl(method, uri);
      request.headers.set(
        'authorization',
        'Bearer manager-token-0123456789abcdef',
      );
      final response = await request.close();
      final text = await response.transform(utf8.decoder).join();
      return {
        'status': response.statusCode,
        'body': text.isEmpty
            ? <String, dynamic>{}
            : jsonDecode(text) as Map<String, dynamic>,
      };
    } finally {
      client.close(force: true);
    }
  }

  test('list/read/diff mengembalikan payload dan meneruskan path', () async {
    final l = await send('GET', '/v1/artifacts', server);
    expect(l['status'], 200);
    expect(lastListDir, '');
    expect((l['body']['files'] as List).first['path'], 'README.md');

    final l2 = await send('GET', '/v1/artifacts?dir=src', server);
    expect(l2['status'], 200);
    expect(lastListDir, 'src');

    final r = await send(
        'GET', '/v1/artifacts/read?path=README%2Emd', server);
    expect(r['status'], 200);
    expect(lastReadPath, 'README.md');
    expect(r['body']['content'], 'halo\n');
    expect(r['body']['bak_exists'], isTrue);

    final d = await send('GET', '/v1/artifacts/diff?path=README.md', server);
    expect(d['status'], 200);
    expect(lastDiffPath, 'README.md');
    expect((d['body']['lines'] as List).length, 3);
  });

  test('path wajib: read/diff tanpa path → 400', () async {
    expect((await send('GET', '/v1/artifacts/read', server))['status'], 400);
    expect((await send('GET', '/v1/artifacts/diff', server))['status'], 400);
  });

  test('401 tanpa auth + 501 bare + POST 404 read-only', () async {
    final client = HttpClient();
    final uri = Uri.parse(
        'http://127.0.0.1:${server.boundPort}/v1/artifacts');
    final request = await client.openUrl('GET', uri);
    final response = await request.close();
    expect(response.statusCode, 401);
    client.close(force: true);

    expect((await send('GET', '/v1/artifacts', bare))['status'], 501);
    expect((await send('POST', '/v1/artifacts', server))['status'], 404);
  });
}

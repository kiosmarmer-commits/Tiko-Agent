import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_flutter/agent_api_client.dart';
import 'package:agent_flutter/data/agent_repository.dart';
import 'package:agent_flutter/data/api_error.dart';
import 'package:flutter_test/flutter_test.dart';

/// Artifacts browser (GUI-P2-04) di atas fake agentd: list/read/diff
/// read-only dengan query path.
void main() {
  group('GUI-P2-04: repository artifacts', () {
    late _ApiServer fake;
    late AgentApiClient client;
    late HttpAgentRepository repo;

    setUp(() async {
      fake = _ApiServer();
      client = AgentApiClient(baseUrl: await fake.start(), token: 't');
      repo = HttpAgentRepository(client);
    });

    tearDown(() async {
      client.close();
      await fake.close();
    });

    test('artifacts() mengembalikan listing typed', () async {
      final r = await repo.artifacts(dir: 'src');
      expect(r.files.length, 2);
      expect(r.files[0].path, 'src/main.dart');
      expect(r.files[0].bytes, 42);
      expect(r.truncated, isTrue);
      expect(fake.lastPath, '/v1/artifacts');
    });

    test('artifactRead mengembalikan konten + bakExists', () async {
      final r = await repo.artifactRead('src/main.dart');
      expect(r.path, 'src/main.dart');
      expect(r.binary, isFalse);
      expect(r.content, 'void main(){}');
      expect(r.bakExists, isTrue);
      expect(r.truncated, isFalse);
    });

    test('artifactDiff mengembalikan baris marker typed', () async {
      final r = await repo.artifactDiff('src/main.dart');
      expect(r.oldExists, isTrue);
      expect(r.newExists, isTrue);
      expect(r.lines.map((l) => l.type), ['=', '-', '+']);
      expect(r.lines[2].text, 'baru');
    });

    test('bearer tetap di header + path ter-encoded di query', () async {
      await repo.artifactRead('folder a/file set.txt');
      expect(fake.lastAuthHeader, 'Bearer t');
      expect(fake.lastReadQuery,
          'path=${Uri.encodeQueryComponent('folder a/file set.txt')}');
    });

    test('daemon tanpa callback 501 not_implemented', () async {
      fake.nextErrorCode = 501;
      fake.nextErrorCodeName = 'not_implemented';
      try {
        await repo.artifacts();
        fail('harusnya melempar');
      } on ApiError catch (e) {
        expect(e.code, ApiErrorCode.notImplemented);
      }
    });
  });
}

class _ApiServer {
  HttpServer? _server;
  String lastAuthHeader = '';
  String lastPath = '';
  String lastReadQuery = '';
  int nextErrorCode = 0;
  String? nextErrorCodeName;

  Future<String> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    unawaited(() async {
      await for (final req in server) {
        lastPath = req.uri.path;
        lastReadQuery = req.uri.query;
        req.response.headers.contentType = ContentType.json;
        final auth = req.headers.value('authorization') ?? '';
        if (lastPath.startsWith('/v1/artifacts')) lastAuthHeader = auth;

        if (nextErrorCode != 0) {
          req.response.statusCode = nextErrorCode;
          req.response.write(jsonEncode(<String, dynamic>{
            'ok': false,
            'code': nextErrorCodeName ?? 'server',
            'error': 'artifacts not configured',
            'retryable': false,
          }));
        } else if (lastPath == '/v1/artifacts' && req.method == 'GET') {
          req.response.write(jsonEncode(<String, dynamic>{
            'files': [
              {'path': 'src/main.dart', 'bytes': 42, 'modified': '2026-11-18T13:00:00.000Z'},
              {'path': 'README.md', 'bytes': 6, 'modified': '2026-11-18T12:00:00.000Z'},
            ],
            'truncated': true,
          }));
        } else if (lastPath == '/v1/artifacts/read' && req.method == 'GET') {
          req.response.write(jsonEncode(<String, dynamic>{
            'path': 'src/main.dart',
            'bytes': 12,
            'binary': false,
            'truncated': false,
            'content': 'void main(){}',
            'bak_exists': true,
          }));
        } else if (lastPath == '/v1/artifacts/diff' && req.method == 'GET') {
          req.response.write(jsonEncode(<String, dynamic>{
            'path': 'src/main.dart',
            'old_exists': true,
            'new_exists': true,
            'lines': [
              {'type': '=', 'text': 'sama'},
              {'type': '-', 'text': 'lama'},
              {'type': '+', 'text': 'baru'},
            ],
            'truncated': false,
          }));
        } else {
          req.response.statusCode = 404;
          req.response.write(jsonEncode(<String, dynamic>{
            'ok': false,
            'code': 'not_found',
            'error': 'not found',
            'retryable': false,
          }));
        }
        await req.response.close();
      }
    }());
    return 'http://127.0.0.1:${server.port}';
  }

  Future<void> close() async {
    await _server?.close(force: true);
  }
}

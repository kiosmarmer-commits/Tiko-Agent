import 'dart:convert';
import 'dart:io';

import 'package:agent_gateway/agent_gateway.dart';
import 'package:test/test.dart';

void main() {
  late HttpApiServer server;
  late String? updatedId;
  late bool updatedPinned;
  late bool updatedArchived;
  late String? updatedTitle;
  late List<String>? bulkIds;
  late String? duplicatedId;
  late String exportedFormat;

  setUp(() async {
    updatedId = null;
    updatedPinned = true;
    updatedArchived = true;
    updatedTitle = null;
    bulkIds = null;
    duplicatedId = null;
    exportedFormat = 'md';
    server = HttpApiServer(
      onMessage: (_) async => 'ok',
      authToken: 'manager-token-0123456789abcdef',
      port: 0,
      updateSession: (id, {title, pinned, archived}) async {
        updatedId = id;
        updatedPinned = pinned ?? updatedPinned;
        updatedArchived = archived ?? updatedArchived;
        updatedTitle = title;
        return id == 's1';
      },
      deleteSessions: (ids) async {
        bulkIds = ids;
        return ids.where((id) => id == 's1' || id == 's2').length;
      },
      duplicateSession: (id) async {
        duplicatedId = id;
        if (id != 's1') return null;
        return {
          'id': 's1-fork-123',
          'title': 's1 (salinan)',
          'channel': 'cli',
          'updated_at': '2026-01-01T00:00:00Z',
          'turns': 2,
        };
      },
      exportSession: (id, format) async {
        exportedFormat = format;
        if (id != 's1') return null;
        return {'content': '# transkrip\n\nisi', 'format': format};
      },
    );
    await server.start();
  });

  tearDown(() async {
    await server.stop();
  });

  Future<(int, Map<String, dynamic>, String)> send(
    String method,
    String path, {
    Object? body,
  }) async {
    final client = HttpClient();
    try {
      final uri = Uri.parse('http://127.0.0.1:${server.boundPort}$path');
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

  test('PATCH /v1/sessions/<id> memperbarui title/pinned/archived', () async {
    final (status, body, _) = await send(
      'PATCH',
      '/v1/sessions/s1',
      body: {'title': 'Riset', 'pinned': true, 'archived': false},
    );
    expect(status, 200);
    expect(body['ok'], isTrue);
    expect(updatedId, 's1');
    expect(updatedTitle, 'Riset');
    expect(updatedPinned, isTrue);
    expect(updatedArchived, isFalse);
  });

  test('PATCH sesi tidak dikenal mengembalikan 404', () async {
    final (status, body, _) =
        await send('PATCH', '/v1/sessions/ghost', body: {'pinned': true});
    expect(status, 404);
    expect(body['code'], isNotEmpty);
  });

  test('PATCH tanpa updateSession fallback ke renameSession', () async {
    final legacy = HttpApiServer(
      onMessage: (_) async => 'ok',
      authToken: 'manager-token-0123456789abcdef',
      port: 0,
      renameSession: (id, title) async => id == 's1' && title == 'Baru',
    );
    await legacy.start();
    final client = HttpClient();
    try {
      final uri =
          Uri.parse('http://127.0.0.1:${legacy.boundPort}/v1/sessions/s1');
      final request = await client.openUrl('PATCH', uri);
      request.headers.set('content-type', 'application/json');
      request.headers
          .set('authorization', 'Bearer manager-token-0123456789abcdef');
      request.add(utf8.encode(jsonEncode({'title': 'Baru'})));
      final response = await request.close();
      expect(response.statusCode, 200);
    } finally {
      client.close(force: true);
      await legacy.stop();
    }
  });

  test('POST /v1/sessions/delete-bulk menghapus beberapa sesi', () async {
    final (status, body, _) = await send(
      'POST',
      '/v1/sessions/delete-bulk',
      body: {
        'ids': ['s1', 's2', 'hantu'],
      },
    );
    expect(status, 200);
    expect(body['deleted'], 2);
    expect(body['requested'], 3);
    expect(bulkIds, hasLength(3));
  });

  test('POST delete-bulk dengan ids kosong mengembalikan 400', () async {
    final (status, body, _) = await send(
      'POST',
      '/v1/sessions/delete-bulk',
      body: {'ids': <String>[]},
    );
    expect(status, 400);
    expect(body['code'], 'invalid_request');
  });

  test('POST /v1/sessions/<id>/duplicate menggandakan sesi', () async {
    final (status, body, _) = await send('POST', '/v1/sessions/s1/duplicate');
    expect(status, 200);
    expect(duplicatedId, 's1');
    expect((body['session'] as Map)['id'], 's1-fork-123');
  });

  test('duplicate sesi tidak dikenal mengembalikan 404', () async {
    final (status, _, _) = await send('POST', '/v1/sessions/ghost/duplicate');
    expect(status, 404);
  });

  test('GET /v1/sessions/<id>/export?format=md mengirim lampiran', () async {
    final client = HttpClient();
    try {
      final uri = Uri.parse(
        'http://127.0.0.1:${server.boundPort}/v1/sessions/s1/export?format=md',
      );
      final request = await client.getUrl(uri);
      request.headers
          .set('authorization', 'Bearer manager-token-0123456789abcdef');
      final response = await request.close();
      final text = await response.transform(utf8.decoder).join();
      expect(response.statusCode, 200);
      expect(
        response.headers.value('content-disposition'),
        contains('session-s1.md'),
      );
      expect(response.headers.contentType?.mimeType, 'text/markdown');
      expect(text, contains('# transkrip'));
      expect(exportedFormat, 'md');
    } finally {
      client.close(force: true);
    }
  });

  test('export format tidak didukung mengembalikan 400', () async {
    final (status, _, _) =
        await send('GET', '/v1/sessions/s1/export?format=pdf');
    expect(status, 400);
  });

  test('export sesi tidak dikenal mengembalikan 404', () async {
    final (status, _, _) = await send('GET', '/v1/sessions/ghost/export');
    expect(status, 404);
  });
}

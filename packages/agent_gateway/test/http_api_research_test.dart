import 'dart:convert';
import 'dart:io';

import 'package:agent_gateway/agent_gateway.dart';
import 'package:test/test.dart';

/// Fase D — REST `/v1/research/*`: daftar run, detail run + laporan,
/// start run baru, dan 501 bila runner tidak dikonfigurasi.

void main() {
  late HttpApiServer server;

  setUp(() async {
    server = HttpApiServer(
      onMessage: (_) async => 'ok',
      authToken: 'manager-token-0123456789abcdef',
      port: 0,
      researchRunsProvider: () async => [
        {
          'run_id': 'r1',
          'question': 'pertanyaan',
          'status': 'ok',
          'summary': 'ringkasan',
        },
      ],
      researchRunGetter: (runId) async => runId == 'r1'
          ? {
              'run': {'run_id': 'r1', 'question': 'pertanyaan', 'status': 'ok'},
              'report': '# laporan',
            }
          : null,
      researchStarter: (body) async => {
        'run_id': 'r2',
        'question': body['question'],
        'status': 'ok',
      },
    );
    await server.start();
  });

  tearDown(() async {
    await server.stop();
  });

  Future<(int, Map<String, dynamic>)> req(
    String method,
    String path, {
    String? body,
  }) async {
    final client = HttpClient();
    try {
      final r = await client.openUrl(
        method,
        Uri.parse('http://127.0.0.1:${server.boundPort}$path'),
      );
      r.headers.set('Authorization', 'Bearer manager-token-0123456789abcdef');
      if (body != null) r.headers.contentType = ContentType.json;
      r.add(utf8.encode(body ?? ''));
      final res = await r.close();
      final text = await utf8.decoder.bind(res).join();
      return (
        res.statusCode,
        text.isEmpty
            ? <String, dynamic>{}
            : jsonDecode(text) as Map<String, dynamic>,
      );
    } finally {
      client.close();
    }
  }

  test('GET /v1/research/runs', () async {
    final (code, json) = await req('GET', '/v1/research/runs');
    expect(code, 200);
    expect((json['runs'] as List).first['run_id'], 'r1');
  });

  test('GET /v1/research/runs/r1 → run + report', () async {
    final (code, json) = await req('GET', '/v1/research/runs/r1');
    expect(code, 200);
    expect((json['run'] as Map)['status'], 'ok');
    expect(json['report'], '# laporan');
  });

  test('GET /v1/research/runs/tidak-ada → 404', () async {
    final (code, json) = await req('GET', '/v1/research/runs/zz');
    expect(code, 404);
    expect(json['code'], 'not_found');
  });

  test('POST /v1/research/run validasi payload', () async {
    final (codeMissing, jsonMissing) = await req(
      'POST',
      '/v1/research/run',
      body: '{}',
    );
    expect(codeMissing, 400);
    expect(jsonMissing['code'], 'invalid_request');

    final (codeBadConc, _) = await req(
      'POST',
      '/v1/research/run',
      body: jsonEncode({'question': 'q', 'max_concurrency': 9}),
    );
    expect(codeBadConc, 400);

    final (codeOk, jsonOk) = await req(
      'POST',
      '/v1/research/run',
      body: jsonEncode({'question': 'q', 'max_concurrency': 2}),
    );
    expect(codeOk, 200);
    expect(jsonOk['question'], 'q');
  });

  test('runner tidak dikonfigurasi → 501', () async {
    final bare = HttpApiServer(
      onMessage: (_) async => 'ok',
      authToken: 'manager-token-0123456789abcdef',
      port: 0,
    );
    await bare.start();
    final client = HttpClient();
    try {
      final r = await client.getUrl(
        Uri.parse('http://127.0.0.1:${bare.boundPort}/v1/research/runs'),
      );
      r.headers.set('Authorization', 'Bearer manager-token-0123456789abcdef');
      final res = await r.close();
      expect(res.statusCode, 501);
    } finally {
      client.close();
      await bare.stop();
    }
  });
}

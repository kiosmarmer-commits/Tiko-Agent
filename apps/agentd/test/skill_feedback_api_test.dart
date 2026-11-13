import 'dart:convert';
import 'dart:io';

import 'package:agent_core/agent_core.dart';
import 'package:agent_gateway/agent_gateway.dart';
import 'package:test/test.dart';
import 'package:tiko_runtime/tiko_runtime.dart';

import '../bin/runtime_skill_api.dart';

void main() {
  late Directory temp;
  late TikoRuntime rt;
  late HttpApiServer server;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('tiko_skill_feedback_');
    await Directory('${temp.path}/skills').create(recursive: true);
    await File('${temp.path}/agent.yaml').writeAsString('''
profile: default
workspace: "."
providers:
  default_chat: mock
  chat:
    mock:
      type: mock
''');
    rt = await TikoRuntime.create(configPath: '${temp.path}/agent.yaml');
    rt.skills.register(Skill(
      slug: 'deploy-helper',
      name: 'deploy-helper',
      description: 'test skill',
      body: 'body',
      status: SkillStatus.approved,
    ));
    rt.skills.register(Skill(
      slug: 'draft-skill',
      name: 'draft-skill',
      description: 'test skill',
      body: 'body',
      status: SkillStatus.draft,
    ));
    server = HttpApiServer(
      onMessage: (_) async => 'ok',
      authToken: 'test-token',
      port: 0,
      skillApi: RuntimeSkillApi(rt),
    );
    await server.start();
  });

  tearDown(() async {
    await server.stop();
    await rt.close();
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  Future<Map<String, dynamic>> post(
    String path,
    Map<String, dynamic> body,
  ) async {
    final client = HttpClient();
    try {
      final req = await client.postUrl(
        Uri.parse('http://127.0.0.1:${server.boundPort}$path'),
      );
      req.headers.set(HttpHeaders.authorizationHeader, 'Bearer test-token');
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(body));
      final res = await req.close();
      final json = jsonDecode(await res.transform(utf8.decoder).join())
          as Map<String, dynamic>;
      return {'status': res.statusCode, ...json};
    } finally {
      client.close();
    }
  }

  test('feedback 👍/👎 via REST mencapai registry dan ledger durabel', () async {
    final res = await post('/v1/skills/deploy-helper/feedback', {
      'positive': true,
    });
    expect(res['status'], 200);
    expect(res['recorded'], isTrue);
    expect((res['metrics'] as Map)['positive'], 1);

    final res2 = await post('/v1/skills/deploy-helper/feedback', {
      'positive': false,
    });
    expect(res2['status'], 200);
    expect((res2['metrics'] as Map)['negative'], 1);

    // The registry sink wrote through to the durable ledger file.
    final ledger = SkillMetricsLedger(
      '${rt.dataDir}/skill_metrics.json',
    );
    await ledger.load();
    expect(ledger.of('deploy-helper')!.positive, 1);
    expect(ledger.of('deploy-helper')!.negative, 1);
  });

  test('skill draft menolak feedback (fail-closed)', () async {
    final res = await post('/v1/skills/draft-skill/feedback', {
      'positive': true,
    });
    expect(res['status'], 200);
    expect(res['error'], isNotNull);
    expect(res['recorded'], isNull);
  });

  test('slug tidak dikenal dan body tidak valid ditolak', () async {
    final unknown = await post('/v1/skills/nope/feedback', {'positive': true});
    expect(unknown['error'], contains('not found'));

    final bad = await post('/v1/skills/deploy-helper/feedback', {
      'positive': 'yes',
    });
    expect(bad['error'], contains('positive'));
  });

  test('GET /v1/skills menyertakan metrik feedback', () async {
    await post('/v1/skills/deploy-helper/feedback', {'positive': true});
    final client = HttpClient();
    try {
      final req = await client.getUrl(
        Uri.parse('http://127.0.0.1:${server.boundPort}/v1/skills'),
      );
      req.headers.set(HttpHeaders.authorizationHeader, 'Bearer test-token');
      final res = await req.close();
      final json = jsonDecode(await res.transform(utf8.decoder).join())
          as Map<String, dynamic>;
      final skills = json['skills'] as List;
      final deploy = skills
          .cast<Map<String, dynamic>>()
          .firstWhere((s) => s['slug'] == 'deploy-helper');
      expect(((deploy['metrics'] as Map)['positive']), 1);
    } finally {
      client.close();
    }
  });
}

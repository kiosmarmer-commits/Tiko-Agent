import 'dart:io';

import 'package:agent_core/agent_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tiko_runtime/tiko_runtime.dart';

Future<String> _prepare(Directory temp) async {
  final configDir = Directory(p.join(temp.path, 'config'))..createSync();
  final config = File(p.join(configDir.path, 'agent.yaml'));
  await config.writeAsString('''
profile: default
workspace: ${temp.path}
storage:
  data_dir: ${p.join(temp.path, 'data')}
providers:
  default_chat: mock
  chat:
    mock:
      type: mock
agent:
  max_iterations: 2
''');
  return config.path;
}

Future<void> _waitUntil(bool Function() cond) async {
  for (var i = 0; i < 100; i++) {
    if (cond()) return;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  fail('kondisi tidak tercapai dalam 10s');
}

void main() {
  late Directory temp;
  late String configPath;

  setUp(() async {
    temp = Directory.systemTemp.createTempSync('tiko_cron_skill_');
    configPath = await _prepare(temp);
  });

  tearDown(() async {
    temp.deleteSync(recursive: true);
  });

  test('job dengan skill terlampir: run sukses tercatat + pemakaian skill',
      () async {
    final rt = await TikoRuntime.create(configPath: configPath);
    addTearDown(rt.close);
    rt.skills.register(Skill(
      slug: 'ringkas',
      name: 'Ringkas',
      description: 'skill tes',
      body: 'Ringkas jawaban akhir dalam tiga kalimat.',
      status: SkillStatus.approved,
    ));
    final job = await rt.jobs.addAndSave(
      cron: '* * * * *',
      prompt: 'ringkas berita hari ini',
      channel: 'cli',
      userKey: 'u1',
      skill: 'ringkas',
    );
    expect(rt.jobs.runNow(job.id), isNotNull);
    rt.startScheduler(tickInterval: const Duration(milliseconds: 100));
    await _waitUntil(() => rt.jobs.get(job.id)?.lastStatus == 'ok');
    final job2 = rt.jobs.get(job.id)!;
    expect(job2.lastStatus, 'ok');
    expect(job2.failureStreak, 0);
    expect(job2.skill, 'ringkas');
    await rt.stopScheduler();
  });

  test('skill hilang: run gagal fail-closed dengan [CRON_FAILURE]', () async {
    final rt = await TikoRuntime.create(configPath: configPath);
    addTearDown(rt.close);
    final job = await rt.jobs.addAndSave(
      cron: '* * * * *',
      prompt: 'apa saja',
      channel: 'cli',
      userKey: 'u1',
      skill: 'tidak-ada',
    );
    expect(rt.jobs.runNow(job.id), isNotNull);
    rt.startScheduler(tickInterval: const Duration(milliseconds: 100));
    await _waitUntil(
        () => rt.jobs.get(job.id)?.failureStreak != null &&
            rt.jobs.get(job.id)!.failureStreak > 0);
    final job2 = rt.jobs.get(job.id)!;
    expect(job2.lastStatus, 'failed');
    expect(job2.lastError, contains('[CRON_FAILURE]'));
    expect(job2.lastError, contains('tidak tersedia'));
    await rt.stopScheduler();
  });

  test('job tanpa skill: run sukses tanpa sentuhan skill', () async {
    final rt = await TikoRuntime.create(configPath: configPath);
    addTearDown(rt.close);
    final job = await rt.jobs.addAndSave(
      cron: '* * * * *',
      prompt: 'halo',
      channel: 'cli',
      userKey: 'u1',
    );
    expect(rt.jobs.runNow(job.id), isNotNull);
    rt.startScheduler(tickInterval: const Duration(milliseconds: 100));
    await _waitUntil(() => rt.jobs.get(job.id)?.lastStatus == 'ok');
    expect(rt.jobs.get(job.id)!.failureStreak, 0);
    await rt.stopScheduler();
  });
}

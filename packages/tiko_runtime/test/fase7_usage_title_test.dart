import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tiko_runtime/tiko_runtime.dart';

Future<String> _prepare(
  Directory temp, {
  double dailyCreditLimitUsd = 0,
  bool autoTitle = true,
}) async {
  final configDir = await Directory(p.join(temp.path, 'config')).create();
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
  max_iterations: 4
  auto_title: $autoTitle
  daily_credit_limit_usd: $dailyCreditLimitUsd
''');
  return config.path;
}

void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('tiko_fase7_');
  });

  tearDown(() async {
    await temp.delete(recursive: true);
  });

  group('Auto-title (Hermes title_generator)', () {
    test('pesan pembuka user → judul derived di-set + event emitted',
        () async {
      final configPath = await _prepare(temp);
      final rt = await TikoRuntime.create(configPath: configPath);
      addTearDown(rt.close);
      await rt.chat('Halo, bagaimana cara deploy Flutter web?');
      final infos = await rt.sessions.list();
      final s = infos.firstWhere((i) => i.id == 'cli:default');
      expect(s.title, 'Halo, bagaimana cara deploy Flutter web?');
      final titled = rt.events
          .recent(limit: 100)
          .where((e) => e['type'] == 'session.titled')
          .toList();
      expect(titled, isNotEmpty);
      expect(titled.first['source'], 'derived');
    });

    test('judul tidak ditimpa turn berikutnya (provenance)', () async {
      final configPath = await _prepare(temp);
      final rt = await TikoRuntime.create(configPath: configPath);
      addTearDown(rt.close);
      await rt.chat('pertanyaan pembuka yang panjang ini layak dijudulkan');
      await rt.chat('turn kedua yang juga cukup panjang untuk dijudulkan');
      final infos = await rt.sessions.list();
      final s = infos.firstWhere((i) => i.id == 'cli:default');
      expect(s.title, 'pertanyaan pembuka yang panjang ini layak',
          reason: 'judul derived cap 48 char di batas kata; turn berikutnya '
              'tidak menimpa (provenance)');
    });

    test('pesan pendek tidak dijudulkan derived; slash tidak bocor', () async {
      final configPath = await _prepare(temp);
      final rt = await TikoRuntime.create(configPath: configPath);
      addTearDown(rt.close);
      await rt.chat('ok');
      await rt.chat('/usage');
      final infos = await rt.sessions.list();
      final s = infos.firstWhere((i) => i.id == 'cli:default');
      expect(s.title, 'ok',
          reason: 'fallback judul store; judul derived tidak dipakai untuk '
              'pesan pendek dan tidak pernah berupa teks slash command');
    });

    test('auto_title: false → tidak ada event session.titled', () async {
      final configPath = await _prepare(temp, autoTitle: false);
      final rt = await TikoRuntime.create(configPath: configPath);
      addTearDown(rt.close);
      await rt.chat('pesan pembuka yang cukup panjang untuk dijudulkan');
      final titled = rt.events
          .recent(limit: 100)
          .where((e) => e['type'] == 'session.titled')
          .toList();
      expect(titled, isEmpty);
    });
  });

  group('/usage — biaya + kredit (Hermes usage_pricing/credits)', () {
    test('/usage menampilkan baris biaya estimasi', () async {
      final configPath = await _prepare(temp);
      final rt = await TikoRuntime.create(configPath: configPath);
      addTearDown(rt.close);
      await rt.chat('turn pertama untuk mengisi ledger');
      final out = await rt.chat('/usage');
      expect(out, contains('biaya (estimasi'));
      expect(out, contains(r'$0.00'));
    });

    test('limit kredit harian dikonfigurasi → baris kredit tampil', () async {
      final configPath = await _prepare(temp, dailyCreditLimitUsd: 10.0);
      final rt = await TikoRuntime.create(configPath: configPath);
      addTearDown(rt.close);
      await rt.chat('turn pertama untuk mengisi ledger');
      final out = await rt.chat('/usage');
      expect(out, contains('kredit hari ini'));
      expect(out, contains(r'$10.00'));
      expect(out, contains('sisa kredit'));
      expect(out, isNot(contains('LIMIT HARIAN TERLAMPAUI')));
    });
  });

  group('CostLedger — agregasi cost_usd (fase-7 C1)', () {
    test('entry dengan cost tersimpan dan diagregasi per bucket', () async {
      final configPath = await _prepare(temp);
      final rt = await TikoRuntime.create(configPath: configPath);
      addTearDown(rt.close);
      final dir = p.join(temp.path, 'data');
      await Directory(dir).create(recursive: true);
      final ledger = CostLedger(persistPath: p.join(dir, 'cost.jsonl'));
      await ledger.record(CostEntry(
        ts: DateTime.now().toUtc(),
        session: 's1',
        channel: 'cli',
        userKey: 'u',
        tokensUsed: 100,
        toolCalls: 0,
        success: true,
        durationMs: 5,
        model: 'gpt-4o',
        costUsd: 0.0035,
      ));
      final s = ledger.summary(days: 7);
      expect((s['total'] as Map<String, dynamic>)['cost_usd'], closeTo(0.0035, 1e-12));
      final bucket = (s['buckets'] as List).first as Map<String, dynamic>;
      expect(bucket['cost_usd'], closeTo(0.0035, 1e-12));
      expect(bucket['key'], 'u');
    });
  });
}

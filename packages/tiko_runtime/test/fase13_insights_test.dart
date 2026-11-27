// Hermes fase-13: session insights engine — agregasi ledger biaya menjadi
// laporan insight (`insightsGenerate` + `insightsFormatTerminal`) dan
// perintah `/insights [days]` di runtime.
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tiko_runtime/tiko_runtime.dart';

Future<String> _prepare(Directory temp, {String agentExtra = ''}) async {
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
$agentExtra
''');
  return config.path;
}

CostEntry _entry({
  required DateTime ts,
  String session = 's1',
  String channel = 'cli',
  String model = 'openai/gpt-5',
  int tokens = 100,
  int toolCalls = 2,
  bool success = true,
  double cost = 0.01,
}) {
  return CostEntry(
    ts: ts,
    session: session,
    channel: channel,
    userKey: 'u1',
    tokensUsed: tokens,
    toolCalls: toolCalls,
    success: success,
    durationMs: 500,
    model: model,
    costUsd: cost,
  );
}

void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('tiko_fase13_');
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  group('unit engine', () {
    test('insightsShortModel: buang prefiks provider, kosong → unknown', () {
      expect(insightsShortModel('openai/gpt-5'), 'gpt-5');
      expect(insightsShortModel('anthropic//claude-x'), 'claude-x');
      expect(insightsShortModel('gpt-5'), 'gpt-5');
      expect(insightsShortModel(''), 'unknown');
      expect(insightsShortModel('  '), 'unknown');
    });

    test('insightsBarChart: proporsional puncak, 0 → kosong', () {
      final bars = insightsBarChart([10, 5, 0], maxWidth: 20);
      expect(bars[0], '█' * 20);
      expect(bars[1], '█' * 10);
      expect(bars[2], '');
      expect(insightsBarChart([], maxWidth: 10), isEmpty);
      expect(insightsBarChart([0, 0]), everyElement(''));
    });

    test('insightsHour12 + insightsDayLabel', () {
      expect(insightsHour12(0), '12am');
      expect(insightsHour12(9), '9am');
      expect(insightsHour12(13), '1pm');
      expect(insightsHour12(12), '12pm');
      expect(
        insightsDayLabel(DateTime.utc(2026, 1, 5)),
        'Jan 05',
      );
    });

    test('generate: overview, model, channel, sesi, aktivitas', () async {
      final ledger = CostLedger(
        persistPath: p.join(temp.path, 'turn_costs.jsonl'),
      );
      final now = DateTime.utc(2026, 2, 10, 15, 30);
      await ledger.record(_entry(ts: now.subtract(const Duration(days: 3)),
          session: 's-a', channel: 'cli', model: 'openai/gpt-5',
          tokens: 400, toolCalls: 4, cost: 0.02));
      await ledger.record(_entry(ts: now.subtract(const Duration(days: 2)),
          session: 's-a', channel: 'cli', model: 'openai/gpt-5',
          tokens: 600, toolCalls: 1, cost: 0.03));
      await ledger.record(_entry(ts: now.subtract(const Duration(days: 1)),
          session: 's-b', channel: 'telegram', model: 'anthropic/claude-y',
          tokens: 100, toolCalls: 0, success: false, cost: 0.01));

      final report = insightsGenerate(
        ledger,
        days: 30,
        now: () => now,
      );
      expect(report['empty'], isFalse);
      final o = report['overview'] as Map<String, dynamic>;
      expect(o['turns'], 3);
      expect(o['success_turns'], 2);
      expect(o['tokens'], 1100);
      expect(o['tool_calls'], 5);
      expect((o['cost_usd'] as double).toStringAsFixed(4), '0.0600');
      expect((o['success_rate'] as double).toStringAsFixed(3), '0.667');

      final models = report['models'] as List;
      expect(models, hasLength(2));
      expect((models[0] as Map)['model'], 'gpt-5');
      expect((models[0] as Map)['tokens'], 1000);

      final channels = report['channels'] as List;
      expect(channels, hasLength(2));
      expect((channels[0] as Map)['channel'], 'cli');
      expect((channels[0] as Map)['turns'], 2);

      final sessions = report['sessions'] as List;
      expect(sessions, hasLength(2));
      expect((sessions[0] as Map)['session'], 's-a');
      expect((sessions[0] as Map)['tokens'], 1000);

      final act = report['activity'] as Map<String, dynamic>;
      expect(act['active_days'], 3);
      expect(act['max_streak'], 3);
      expect((act['busiest_day'] as Map)['count'], greaterThan(0));
    });

    test('generate: window days memfilter entri lama; ledger kosong → empty',
        () async {
      final ledger = CostLedger(
        persistPath: p.join(temp.path, 'turn_costs.jsonl'),
      );
      final now = DateTime.utc(2026, 2, 10);
      await ledger.record(_entry(ts: now.subtract(const Duration(days: 40))));
      final old = insightsGenerate(ledger, days: 30, now: () => now);
      expect(old['empty'], isTrue);
      final fresh = insightsGenerate(ledger, days: 60, now: () => now);
      expect(fresh['empty'], isFalse);

      final emptyLedger = CostLedger(
        persistPath: p.join(temp.path, 'kosong.jsonl'),
      );
      final emptyReport =
          insightsGenerate(emptyLedger, days: 30, now: () => now);
      expect(emptyReport['empty'], isTrue);
      expect(insightsFormatTerminal(emptyReport),
          contains('Tidak ada data sesi'));
    });
  });

  group('format terminal', () {
    test('berisi header, overview, model, channel, aktivitas, sesi', () async {
      final ledger = CostLedger(
        persistPath: p.join(temp.path, 'turn_costs.jsonl'),
      );
      final now = DateTime.utc(2026, 2, 10, 15, 30);
      await ledger.record(_entry(ts: now.subtract(const Duration(days: 1)),
          session: 's-a', channel: 'cli', model: 'openai/gpt-5',
          tokens: 500, toolCalls: 3, cost: 0.02));
      await ledger.record(_entry(ts: now.subtract(const Duration(days: 1)),
          session: 's-b', channel: 'telegram', model: 'openai/gpt-5',
          tokens: 300, toolCalls: 1, cost: 0.01));

      final out = insightsFormatTerminal(
        insightsGenerate(ledger, days: 30, now: () => now),
      );
      expect(out, contains('Tiko Insights'));
      expect(out, contains('Overview'));
      expect(out, contains('Model Terpakai'));
      expect(out, contains('gpt-5'));
      expect(out, contains('Channel'));
      expect(out, contains('telegram'));
      expect(out, contains('Pola Aktivitas'));
      expect(out, contains('█'));
      expect(out, contains('Sesi Teratas'));
      expect(out, contains('s-a'));
    });

    test('gateway format ringkas dengan markdown', () {
      final report = <String, dynamic>{
        'days': 7,
        'empty': false,
        'overview': {
          'turns': 4,
          'tokens': 900,
          'tool_calls': 2,
          'cost_usd': 0.05,
        },
        'models': [
          {'model': 'gpt-5', 'turns': 4, 'tokens': 900},
        ],
        'activity': {
          'busiest_day': {'day': 'Sen', 'count': 3},
          'busiest_hour': {'hour': 13, 'count': 2},
          'active_days': 2,
          'max_streak': 2,
        },
      };
      final out = insightsFormatGateway(report);
      expect(out, contains('**Tiko Insights**'));
      expect(out, contains('gpt-5'));
      expect(out, contains('1pm'));
      expect(out, contains('**Streak terbaik:** 2 hari berturut'));
      expect(
        insightsFormatGateway(<String, dynamic>{'days': 7, 'empty': true}),
        contains('Tidak ada data'),
      );
    });
  });

  group('perintah runtime', () {
    test('/insights: laporan kosong jujur saat ledger kosong', () async {
      final configPath = await _prepare(temp);
      final rt = await TikoRuntime.create(configPath: configPath);
      addTearDown(rt.close);
      final out = await rt.chat('/insights');
      expect(out, contains('Tidak ada data sesi'));
    });

    test('/insights: setelah turn mock, laporan berisi overview', () async {
      final configPath = await _prepare(temp);
      final rt = await TikoRuntime.create(configPath: configPath);
      addTearDown(rt.close);
      await rt.chat('halo');
      final out = await rt.chat('/insights');
      expect(out, contains('Tiko Insights'));
      expect(out, contains('Turn:'));
    });

    test('/insights 7: jendela hari dipakai; argumen jelek gagal jujur',
        () async {
      final configPath = await _prepare(temp);
      final rt = await TikoRuntime.create(configPath: configPath);
      addTearDown(rt.close);
      final out = await rt.chat('/insights 7');
      expect(out, contains('7 hari terakhir'));
      final bad = await rt.chat('/insights seminggu');
      expect(bad, contains('Argumen hari tidak valid'));
      final zero = await rt.chat('/insights 0');
      expect(zero, contains('Argumen hari tidak valid'));
    });
  });
}

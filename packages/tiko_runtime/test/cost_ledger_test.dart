import 'dart:convert';
import 'dart:io';

import 'package:tiko_runtime/tiko_runtime.dart';
import 'package:test/test.dart';

/// Fase F7 (docs/15 §8) — cost/token observability: ledger durabel +
/// agregasi per user/channel/day untuk halaman Runs.
void main() {
  CostEntry entry({
    DateTime? ts,
    String user = 'u1',
    String channel = 'cli',
    int tokens = 100,
    int calls = 2,
    bool success = true,
  }) =>
      CostEntry(
        ts: ts ?? DateTime.now().toUtc(),
        session: 's:$user',
        channel: channel,
        userKey: user,
        tokensUsed: tokens,
        toolCalls: calls,
        success: success,
        durationMs: 10,
      );

  group('CostEntry', () {
    test('toJson/fromJson roundtrip', () {
      final e = entry();
      final back = CostEntry.fromJson(e.toJson());
      expect(back.userKey, e.userKey);
      expect(back.tokensUsed, e.tokensUsed);
      expect(back.success, e.success);
      expect(back.ts, e.ts);
    });

    test('fromJson invalid -> FormatException', () {
      expect(
        () => CostEntry.fromJson({'ts': 'bukan-tanggal', 'tokens_used': 1}),
        throwsFormatException,
      );
      expect(
        () => CostEntry.fromJson({
          'ts': DateTime.now().toUtc().toIso8601String(),
          'tokens_used': 'bukan-int',
        }),
        throwsFormatException,
      );
    });
  });

  group('CostLedger', () {
    test('record -> save -> load roundtrip + empty line skip', () async {
      final dir = Directory.systemTemp.createTempSync('cost_ledger_');
      final path = '${dir.path}/turn_costs.jsonl';
      final ledger = CostLedger(persistPath: path, maxEntries: 100);
      await ledger.load();
      await ledger.record(entry(user: 'alice', tokens: 500));
      await ledger.record(entry(user: 'bob', tokens: 200, success: false));
      await File(path).writeAsString('\n', mode: FileMode.append);

      final loaded = CostLedger(persistPath: path, maxEntries: 100);
      await loaded.load();
      expect(loaded.length, 2);
      final buckets = (loaded.summary(groupBy: 'user')['buckets'] as List);
      expect((buckets.first as Map)['key'], 'alice');

      dir.deleteSync(recursive: true);
    });

    test('cap maxEntries: entri tertua dibuang', () async {
      final dir = Directory.systemTemp.createTempSync('cost_ledger_cap_');
      final ledger = CostLedger(
        persistPath: '${dir.path}/turn_costs.jsonl',
        maxEntries: 5,
      );
      await ledger.load();
      for (var i = 0; i < 8; i++) {
        await ledger.record(entry(user: 'u$i', tokens: 10 + i));
      }
      expect(ledger.length, 5);
      final keys = [
        for (final b in (ledger.summary()['buckets'] as List))
          (b as Map)['key'],
      ];
      expect(keys, isNot(contains('u0')));
      expect(keys, contains('u7'));
      dir.deleteSync(recursive: true);
    });

    test('file korup -> fail-soft (mulai kosong, record berikutnya menimpa)',
        () async {
      final dir = Directory.systemTemp.createTempSync('cost_ledger_corrupt_');
      final path = '${dir.path}/turn_costs.jsonl';
      await File(path).writeAsString('{korup bukan jsonl}\n{"_partial":');
      final ledger = CostLedger(persistPath: path, maxEntries: 10);
      await ledger.load();
      expect(ledger.length, 0);
      await ledger.record(entry(user: 'recover'));
      final loaded = CostLedger(persistPath: path, maxEntries: 10);
      await loaded.load();
      expect(loaded.length, 1);
      dir.deleteSync(recursive: true);
    });

    test('summary: grouping channel vs day + jendela days', () async {
      final dir = Directory.systemTemp.createTempSync('cost_ledger_sum_');
      final ledger = CostLedger(
        persistPath: '${dir.path}/turn_costs.jsonl',
        maxEntries: 100,
      );
      await ledger.load();
      final now = DateTime.now().toUtc();
      await ledger.record(
        entry(user: 'u1', channel: 'telegram', ts: now, tokens: 300),
      );
      await ledger.record(
        entry(
          user: 'u1',
          channel: 'cli',
          ts: now.subtract(const Duration(days: 2)),
          tokens: 700,
        ),
      );
      await ledger.record(
        entry(
          user: 'u2',
          channel: 'cli',
          ts: now.subtract(const Duration(days: 30)),
          tokens: 999999,
        ),
      );

      final byChannel = ledger.summary(groupBy: 'channel', days: 7);
      expect(byChannel['total']['tokens_used'], 1000);
      final channelKeys = [
        for (final b in byChannel['buckets'] as List) b['key'],
      ];
      expect(channelKeys, ['cli', 'telegram']);
      final cliBucket = (byChannel['buckets'] as List)
          .firstWhere((b) => b['key'] == 'cli') as Map;
      expect(cliBucket['turns'], 1);
      expect(cliBucket['tokens_used'], 700);

      // Entri 30 hari lalu keluar dari jendela default 7 hari.
      final byUser = ledger.summary(groupBy: 'user', days: 1);
      expect(byUser['total']['tokens_used'], 300);
      final dayKeys = [
        for (final b in ledger.summary(groupBy: 'day')['buckets'] as List)
          b['key'],
      ];
      expect(dayKeys.length, 2);
      expect(
        dayKeys.toSet(),
        {
          now.toIso8601String().substring(0, 10),
          now.subtract(const Duration(days: 2)).toIso8601String().substring(0, 10),
        },
      );

      dir.deleteSync(recursive: true);
    });
  });

  group('runtime wiring', () {
    late Directory temp;
    late TikoRuntime rt;

    setUp(() async {
      temp = await Directory.systemTemp.createTemp('f7-cost-test');
      final configPath = File('${temp.path}/config.yaml');
      await configPath.writeAsString('''
providers:
  mock:
    type: openai_compat
    base_url: http://127.0.0.1:1/v1
    api_key: sk-test
default_provider: mock
data_dir: ${temp.path}/data
memory:
  backend: json
logs_dir: ${temp.path}/logs
workspace: ${temp.path}/workspace
security:
  mode: ask
mcp:
  servers: []
''');
      rt = await TikoRuntime.create(configPath: configPath.path);
      addTearDown(rt.close);
    });

    tearDown(() async {
      await temp.delete(recursive: true);
    });

    test('turn selesai (apapun statusnya) tercatat di ledger + snapshot cost',
        () async {
      final result = await rt.chatWithStatus('ping');
      await rt.costLedger.load();
      final file = File('${temp.path}/data/turn_costs.jsonl');
      expect(file.existsSync(), isTrue);
      final lines = [
        for (final line in file.readAsLinesSync())
          if (line.trim().isNotEmpty) line,
      ];
      expect(lines, hasLength(1));
      final recorded = jsonDecode(lines.single) as Map<String, dynamic>;
      expect(recorded['success'], result.success);
      expect(recorded['tokens_used'], result.tokensUsed);
      expect(recorded['user_key'], 'local');

      final snapshot = rt.turnInspectorSnapshot();
      final cost = snapshot['cost'] as Map<String, dynamic>;
      expect(cost['total']['turns'], 1);
      expect(cost['total']['success'], result.success ? 1 : 0);
      expect(cost['total']['tokens_used'], result.tokensUsed);
    });
  });
}

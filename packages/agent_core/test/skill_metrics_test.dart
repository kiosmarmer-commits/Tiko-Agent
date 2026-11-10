import 'dart:io';

import 'package:agent_core/agent_core.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('tiko_skill_metrics_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  String pth(String name) => '${tmp.path}/$name';

  test('recordUse terpersist dan bisa dibaca ulang', () async {
    final a = SkillMetricsLedger(pth('m.json'));
    await a.recordUse('satu', success: true);
    await a.recordUse('satu', success: false);

    final b = SkillMetricsLedger(pth('m.json'));
    await b.load();
    expect(b.of('satu')!.uses, 2);
    expect(b.of('satu')!.successes, 1);
    expect(b.of('satu')!.lastUsedAt, isNotNull);
  });

  test('recordFeedback tercatat terpisah dari uses', () async {
    final a = SkillMetricsLedger(pth('f.json'));
    await a.recordFeedback('satu', positive: true);
    await a.recordFeedback('satu', positive: false);

    final b = SkillMetricsLedger(pth('f.json'));
    await b.load();
    expect(b.of('satu')!.uses, 0);
    expect(b.of('satu')!.positive, 1);
    expect(b.of('satu')!.negative, 1);
  });

  test('file korup gagal tertutup: ledger kosong', () async {
    File(pth('corrupt.json')).writeAsStringSync('{not json');
    final l = SkillMetricsLedger(pth('corrupt.json'));
    await l.load();
    expect(l.metrics, isEmpty);
  });

  test('applyTo memulihkan uses/successes saja', () async {
    final ledger = SkillMetricsLedger(pth('m.json'));
    await ledger.recordUse('demo', success: true);
    await ledger.recordUse('demo', success: true);
    final reg = SkillRegistry();
    reg.register(Skill(
      slug: 'demo',
      name: 'Demo',
      description: 'd',
      body: 'b',
    ));
    ledger.applyTo(reg);
    expect(reg.get('demo')!.uses, 2);
    expect(reg.get('demo')!.successes, 2);
  });

  test('pruning memangkas entri terlama di atas maxSkills', () async {
    final l = SkillMetricsLedger(pth('m.json'), maxSkills: 10);
    for (var i = 0; i < 12; i++) {
      await l.recordUse('s$i', success: true);
    }
    expect(l.metrics.length, 10);
    expect(l.of('s0'), isNull);
    expect(l.of('s11'), isNotNull);
  });

  test('sink registry dipanggil setelah recordUse', () async {
    final reg = SkillRegistry();
    reg.register(Skill(
      slug: 'demo',
      name: 'Demo',
      description: 'd',
      body: 'b',
    ));
    final seen = <String>[];
    reg.onUseRecorded = (slug, {required success}) async {
      seen.add('$slug:$success');
    };
    reg.recordUse('demo', success: true);
    var tries = 0;
    while (seen.isEmpty && tries < 20) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      tries++;
    }
    expect(seen, ['demo:true']);
  });
}

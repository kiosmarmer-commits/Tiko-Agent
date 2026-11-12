import 'dart:io';
import 'dart:convert';

import 'package:agent_core/agent_core.dart';
import 'package:agent_tools/agent_tools.dart';
import 'package:test/test.dart';

void main() {
  final session = Session(id: 's', channel: 'cli', userKey: 'u');
  ToolContext ctx() => ToolContext(session: session, workspacePath: '.');

  List<Map<String, dynamic>> sampleCandles() {
    final candles = <Map<String, dynamic>>[];
    var price = 100.0;
    for (var i = 0; i < 80; i++) {
      price += (i % 7 - 3) * 0.8 + 0.15;
      candles.add({
        'waktu': DateTime.utc(2026, 1, 1).add(Duration(days: i)).toIso8601String(),
        'open': price - 0.3,
        'high': price + 0.6,
        'low': price - 0.7,
        'close': price,
        'volume': 1000 + i * 10,
      });
    }
    return candles;
  }

  Map<String, dynamic> prediksiToolsByName() => {
        for (final t in createPrediksiTools()) t.spec.name: t,
      };

  test('kelima tool prediksi terdaftar di createBuiltinTools', () {
    final all = createBuiltinTools();
    final names = all.map((t) => t.spec.name).toSet();
    for (final n in [
      'prediksi_teknikal',
      'prediksi_ensemble',
      'prediksi_siklus',
      'prediksi_backtest',
      'prediksi_risiko',
    ]) {
      expect(names, contains(n), reason: '$n harus ada di builtin tools');
    }
  });

  test('spec prediksi: risk low + parallelSafe + schema candles required', () {
    for (final t in createPrediksiTools()) {
      expect(t.spec.risk, 'low', reason: '${t.spec.name} harus risk low');
      expect(t.spec.parallelSafe, isTrue);
      expect(t.spec.inputSchema['type'], 'object');
    }
    expect(
      (prediksiToolsByName()['prediksi_teknikal']!.spec.inputSchema['required']
          as List),
      contains('candles'),
    );
  });

  test('prediksi_teknikal e2e: sinyal valid dari candle contoh', () async {
    final tool = prediksiToolsByName()['prediksi_teknikal']!;
    final r = await tool.run({'candles': sampleCandles()}, ctx());
    expect(r.isError, isFalse, reason: r.content);
    final body = jsonDecode(r.content) as Map<String, dynamic>;
    expect(body['metode'], isNotEmpty);
    expect(['beli', 'jual', 'tahan'], contains(body['arah']));
    final skor = body['skor'] as num;
    expect(skor >= -1.0 && skor <= 1.0, isTrue);
  });

  test('prediksi_ensemble e2e: multi-metode + skor dalam rentang', () async {
    final tool = prediksiToolsByName()['prediksi_ensemble']!;
    final r = await tool.run({'candles': sampleCandles()}, ctx());
    expect(r.isError, isFalse, reason: r.content);
    final body = jsonDecode(r.content) as Map<String, dynamic>;
    final sinyal = body['sinyal'] as Map<String, dynamic>;
    expect(['beli', 'jual', 'tahan'], contains(sinyal['arah']));
    final skor = sinyal['skor'] as num;
    expect(skor >= -1.0 && skor <= 1.0, isTrue);
  });

  test('prediksi_siklus e2e: hasil siklus tanpa candle', () async {
    final tool = prediksiToolsByName()['prediksi_siklus']!;
    final r = await tool.run({'tanggal': '2026-11-12'}, ctx());
    expect(r.isError, isFalse, reason: r.content);
  });

  test('prediksi_backtest e2e: metrik backtest dari candle contoh', () async {
    final tool = prediksiToolsByName()['prediksi_backtest']!;
    final r = await tool.run({
      'candles': sampleCandles(),
      'mulai': 40,
    }, ctx());
    expect(r.isError, isFalse, reason: r.content);
  });

  test('prediksi_risiko e2e: stop/posisi dari candle + input risiko', () async {
    final tool = prediksiToolsByName()['prediksi_risiko']!;
    final r = await tool.run({
      'candles': sampleCandles(),
      'modal': 10000000,
      'risiko_persen': 1.0,
    }, ctx());
    expect(r.isError, isFalse, reason: r.content);
  });

  test('input invalid -> ToolResult isError (fail-closed), bukan throw', () async {
    final tool = prediksiToolsByName()['prediksi_teknikal']!;
    final r = await tool.run({'candles': 'bukan-list'}, ctx());
    expect(r.isError, isTrue);
  });

  test('skill prediksi-pasar dimuat SkillRegistry dan merujuk tool yang ada',
      () async {
    final skillFile =
        File('../../skills/prediksi-pasar/SKILL.md');
    if (!await skillFile.exists()) {
      markTestSkipped('skill dir tidak ada di workspace test ini');
      return;
    }
    final registry = SkillRegistry();
    final n = await registry.loadFromDirectory('../../skills');
    expect(n, greaterThan(0));
    final skill = registry.get('prediksi-pasar');
    expect(skill, isNotNull);
    expect(skill!.tools, isNotEmpty);
    final builtinNames = createBuiltinTools().map((t) => t.spec.name).toSet();
    for (final t in skill.tools) {
      expect(builtinNames, contains(t), reason: 'tool $t dirujuk skill');
    }
  });
}

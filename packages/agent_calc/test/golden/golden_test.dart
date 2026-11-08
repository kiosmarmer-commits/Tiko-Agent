import 'dart:convert';
import 'dart:io';

import 'package:agent_calc/agent_calc.dart';
import 'package:test/test.dart';

/// Runner golden (CALC-TST-01): nilai harapan TIDAK dihasilkan kode yang
/// diuji - dibaca dari fixtures/golden_verified.json, dibandingkan sebagai
/// string desimal persis.
void main() {
  final file = File('fixtures/golden_verified.json');
  if (!file.existsSync()) {
    test('fixture golden_verified.json harus ada', () {
      fail('fixture tidak ditemukan: ${file.path}');
    });
    return;
  }
  final data = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  final cases = (data['cases'] as List<dynamic>).cast<Map<String, dynamic>>();

  for (final c in cases) {
    test('golden ${c['id']}', () {
      final op = c['op'] as String;
      final a = Dec.parse(c['a'] as String);
      final expected = c['expected'] as String;
      final result = switch (op) {
        'add' => (a + Dec.parse(c['b'] as String)).toString(),
        'round' => a
            .roundTo(
              c['scale'] as int,
              RoundingMode.fromName(c['mode'] as String),
            )
            .toString(),
        'divide' => a
            .divide(
              Dec.parse(c['b'] as String),
              scale: c['scale'] as int,
              mode: RoundingMode.fromName(c['mode'] as String),
            )
            .toString(),
        _ => fail('op tidak dikenal: $op'),
      };
      expect(result, expected);
    });
  }
}

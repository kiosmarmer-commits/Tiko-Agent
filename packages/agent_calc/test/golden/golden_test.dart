import 'dart:convert';
import 'dart:io';

import 'package:agent_calc/agent_calc.dart';
import 'package:test/test.dart';

const _engine = CalcEngine();

/// Runner golden (CALC-TST-01): nilai harapan TIDAK dihasilkan kode yang
/// diuji - dibaca dari fixtures/golden_verified.json, dibandingkan
/// sebagai string desimal persis.
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
      final expected = c['expected'] as String;
      switch (op) {
        case 'add':
          expect(
            (Dec.parse(c['a'] as String) + Dec.parse(c['b'] as String))
                .toString(),
            expected,
          );
        case 'round':
          expect(
            Dec.parse(c['a'] as String)
                .roundTo(
                  c['scale'] as int,
                  RoundingMode.fromName(c['mode'] as String),
                )
                .toString(),
            expected,
          );
        case 'divide':
          expect(
            Dec.parse(c['a'] as String)
                .divide(
                  Dec.parse(c['b'] as String),
                  scale: c['scale'] as int,
                  mode: RoundingMode.fromName(c['mode'] as String),
                )
                .toString(),
            expected,
          );
        case 'eval':
          final r = _engine.evaluate(
            c['expression'] as String,
            scale: (c['scale'] as num?)?.toInt() ?? 12,
          );
          if (!r.ok) {
            fail('eval gagal (${c['id']}): ${r.error}');
          }
          expect(r.value, expected);
          final w = c['warnings'] as List<dynamic>?;
          if (w != null) {
            expect(r.warnings, containsAll(w.cast<String>()));
          }
        default:
          fail('op tidak dikenal: $op');
      }
    });
  }
}

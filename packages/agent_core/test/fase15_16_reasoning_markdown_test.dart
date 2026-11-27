// Hermes fase-15 (`agent/reasoning_effort.py`) + fase-16 (markdown table
// realign) — uji fungsi murni agent_core.
import 'package:agent_core/agent_core.dart';
import 'package:test/test.dart';

void main() {
  group('Reasoning effort (fase-15)', () {
    test('ladder canonical + isKnownEffort', () {
      expect(effortLadder.first, 'none');
      expect(effortLadder.last, 'ultra');
      expect(isKnownEffort('high'), isTrue);
      expect(isKnownEffort('HIGH'), isTrue, reason: 'case-insensitive');
      expect(isKnownEffort('bananas'), isFalse);
      expect(isKnownEffort(null), isFalse);
    });

    test('clampEffort: verbatim bila didukung', () {
      expect(
        clampEffort('high', ['low', 'medium', 'high']),
        'high',
      );
    });

    test('clampEffort: tak didukung -> level lebih lemah terdekat', () {
      // Set wire tanpa xhigh/max: level atas diklem ke 'high'.
      const supported = ['none', 'minimal', 'low', 'medium', 'high'];
      expect(clampEffort('xhigh', supported), 'high');
      expect(clampEffort('max', supported), 'high');
      expect(clampEffort('ultra', supported), 'high');
    });

    test('clampEffort: tanpa kandidat di bawah -> terlemah yang didukung', () {
      expect(clampEffort('high', ['minimal']), 'minimal');
    });

    test('clampEffort: unset / tanpa supported tetap unset', () {
      expect(clampEffort(null, ['low']), isNull);
      expect(clampEffort('high', null), 'high');
      expect(clampEffort('high', []), 'high');
    });

    test('anthropic thinking budget & adaptive map', () {
      expect(anthropicThinkingBudgetFor('high'), 16000);
      expect(anthropicThinkingBudgetFor('minimal'), 8000);
      expect(anthropicThinkingBudgetFor('none'), isNull);
      expect(anthropicAdaptiveEffortFor('ultra'), 'max');
      expect(anthropicAdaptiveEffortFor('minimal'), 'low');
      expect(anthropicAdaptiveEffortFor('none'), isNull);
    });
  });

  group('Markdown tables (fase-16)', () {
    test('tabel rapi: kolom direalokasi lebar terpanjang sel', () {
      const src = '| A | B |\n| --- | --- |\n| satu | dua |\n';
      final out = realignMarkdownTables(src);
      expect(out, contains('| A    | B   |'));
      expect(out, contains('| satu | dua |'));
    });

    test('pipe dalam kode inline tidak memecah sel', () {
      const src = '| Ekspresi | Hasil |\n'
          '| --- | --- |\n'
          '| `a \\| b` | union |\n';
      final out = realignMarkdownTables(src);
      expect(out, contains(r'a \| b'));
      expect(out.split('\n').first.split('|').length, greaterThanOrEqualTo(4));
    });

    test('teks tanpa pipe dikembalikan identik', () {
      const src = 'paragraf biasa tanpa tabel\nbaris kedua\n';
      expect(realignMarkdownTables(src), src);
    });

    test('availableWidth: lebar cukup -> tabel tetap pipe; sempit -> vertikal', () {
      const src = '| Kunci | Nilai |\n| --- | --- |\n| x | kalimat yang juga panjang dan harus dibungkus rapi |\n';
      final wide = realignMarkdownTables(src, availableWidth: 200);
      expect(wide.contains('|'), isTrue);
      final narrow = realignMarkdownTables(src, availableWidth: 24);
      // Sempit ekstrem: render vertikal (tanpa baris tabel) tetap informatif.
      expect(narrow.contains('Kunci'), isTrue);
      expect(narrow, isNot(contains('---')));
    });
  });
}

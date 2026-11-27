// Hermes fase-14: plan mode prompt (`agent/plan_prompt.py`) — buildPlanPrompt,
// parsePlanCommand, dan planFileName.
import 'package:agent_core/agent_core.dart';
import 'package:test/test.dart';

void main() {
  group('buildPlanPrompt', () {
    test('dengan tugas: marker, aturan, blok tugas, craft', () {
      final prompt = buildPlanPrompt('Tambah endpoint /health');
      expect(prompt, startsWith(planModeMarker));
      expect(prompt, contains('PLAN MODE'));
      expect(prompt, contains('Tugas yang direncanakan:'));
      expect(prompt, contains('Tambah endpoint /health'));
      expect(prompt, contains('plans/YYYY-MM-DD_HHMMSS-<slug>.md'));
      expect(prompt, contains('DRY, YAGNI, TDD'));
      expect(prompt, contains('jangan mulai mengeksekusi'));
    });

    test('tanpa tugas: instruksi infer dari konteks', () {
      final prompt = buildPlanPrompt();
      expect(prompt, isNot(contains('Tugas yang direncanakan:')));
      expect(prompt, contains('infer tugas dari konteks percakapan'));
      expect(prompt, contains('pertanyaan klarifikasi singkat'));
    });

    test('tugas whitespace saja diperlakukan kosong', () {
      final prompt = buildPlanPrompt('   \n\t  ');
      expect(prompt, contains('infer tugas dari konteks percakapan'));
    });
  });

  group('parsePlanCommand', () {
    test('varian valid', () {
      expect(parsePlanCommand('/plan'), '');
      expect(parsePlanCommand('  /plan  '), '');
      expect(parsePlanCommand('/plan refactor auth'), 'refactor auth');
      expect(parsePlanCommand('  /plan   buat fitur X  '), 'buat fitur X');
    });

    test('bukan perintah plan → null (tanpa prefix sebagian)', () {
      expect(parsePlanCommand('/plans'), isNull);
      expect(parsePlanCommand('/planning'), isNull);
      expect(parsePlanCommand('/planx y'), isNull);
      expect(parsePlanCommand('halo /plan'), isNull);
      expect(parsePlanCommand(''), isNull);
    });
  });

  group('planFileName', () {
    test('stamp + slug alnum dari tugas', () {
      final name = planFileName(
        DateTime.utc(2026, 2, 10, 7, 5, 3),
        'Tambah Endpoint /health-check v2',
      );
      expect(name, '2026-02-10_070503-tambah-endpoint-health-check-v2.md');
    });

    test('tugas kosong → slug plan; non-ASCII jadi tanda hubung', () {
      expect(
        planFileName(DateTime.utc(2026, 12, 31, 23, 59, 59), ''),
        '2026-12-31_235959-plan.md',
      );
      final name = planFileName(DateTime.utc(2026, 1, 1), 'résumé ✓ A');
      // é = 2 UTF-16 code unit; unit non-alnum berurutan → satu tanda hubung.
      expect(name, '2026-01-01_000000-r-sum-a.md');
    });

    test('slug dipangkas 40 char tanpa tanda hubung ekor', () {
      final name = planFileName(
        DateTime.utc(2026, 1, 1),
        'a' * 60,
      );
      final slug = name.substring('2026-01-01_000000-'.length);
      expect(slug.startsWith('a' * 40), isTrue);
      expect(slug.endsWith('.md'), isTrue);
      expect(name.length, '2026-01-01_000000-'.length + 40 + '.md'.length);
    });
  });
}

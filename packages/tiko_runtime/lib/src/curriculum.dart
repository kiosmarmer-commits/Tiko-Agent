import 'dart:convert';
import 'dart:io';

import 'package:agent_core/agent_core.dart';

/// Fase 47 — Automatic curriculum (paritas paper Voyager): kurikulum latihan
/// skill bertahap yang dibangun deterministik dari hasil benchmark (EVAL-02)
/// — skill terlemah didahulukan, level naik hanya lewat hasil verifikasi.
///
/// Konvensi repo:
/// - Tanpa LLM: plan/next/advance murni deterministik dari pass-rate.
/// - Persist lokal `<dataDir>/curriculum.json` (atomic tmp+rename, fail-open
///   terhadap file korup).
/// - Never-raises: semua operasi mengembalikan laporan jujur.
class CurriculumLesson {
  CurriculumLesson({
    required this.skill,
    required this.level,
    this.status = 'todo',
    this.attempts = 0,
    this.lastPassRate = 0,
    DateTime? updatedAt,
  }) : updatedAt = updatedAt ?? DateTime.now().toUtc();

  final String skill;

  /// 0 (baru) .. 3 (mahir). Naik hanya bila latihan berikutnya lulus.
  int level;
  String status; // todo | active | done
  int attempts;
  double lastPassRate;
  DateTime updatedAt;

  Map<String, dynamic> toJson() => {
        'skill': skill,
        'level': level,
        'status': status,
        'attempts': attempts,
        'last_pass_rate': lastPassRate,
        'updated_at': updatedAt.toUtc().toIso8601String(),
      };

  static CurriculumLesson? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final skill = raw['skill'];
    if (skill is! String || skill.trim().isEmpty) return null;
    return CurriculumLesson(
      skill: skill.trim(),
      level: raw['level'] is int ? (raw['level'] as int).clamp(0, 3) : 0,
      status: raw['status'] is String ? raw['status'] as String : 'todo',
      attempts: raw['attempts'] is int ? raw['attempts'] as int : 0,
      lastPassRate: raw['last_pass_rate'] is num
          ? (raw['last_pass_rate'] as num).toDouble().clamp(0, 1)
          : 0,
      updatedAt: DateTime.tryParse('${raw['updated_at'] ?? ''}') ??
          DateTime.now().toUtc(),
    );
  }
}

class CurriculumStore {
  CurriculumStore({required this.path, this.maxLessons = 512});

  final String path;
  final int maxLessons;

  final Map<String, CurriculumLesson> lessons = {};
  bool _loaded = false;

  bool get isLoaded => _loaded;

  /// Sinkron idempoten (read-only store kecil) — dipakai `planned()` agar
  /// snapshot/next selalu melihat data ter-persist.
  void ensureLoadedSync() {
    if (_loaded) return;
    _loaded = true;
    try {
      final decoded = jsonDecode(File(path).readAsStringSync());
      if (decoded is! Map) return;
      final list = decoded['lessons'];
      if (list is! List) return;
      for (final raw in list) {
        final lesson = CurriculumLesson.fromJson(raw);
        if (lesson != null) lessons[lesson.skill] = lesson;
      }
    } catch (_) {
      lessons.clear();
    }
  }

  Future<void> load() async => ensureLoadedSync();

  Future<void> save() async {
    try {
      final list = lessons.values.toList()
        ..sort((a, b) => a.skill.compareTo(b.skill));
      while (list.length > maxLessons) {
        final evict = list.removeAt(0);
        lessons.remove(evict.skill);
      }
      final f = File(path);
      await f.parent.create(recursive: true);
      final tmp = File('${f.path}.tmp');
      await tmp.writeAsString(const JsonEncoder.withIndent('  ').convert({
        'lessons': [for (final l in list) l.toJson()],
      }));
      await tmp.rename(f.path);
    } catch (_) {
      // fail-open
    }
  }
}

/// Kurikulum deterministik dari pass-rate benchmark. Murni (store injected).
class SkillCurriculum {
  SkillCurriculum({
    required this.store,
    this.maxActiveLessons = 10,
    this.emitEvent,
  }) : assert(maxActiveLessons >= 1 && maxActiveLessons <= 64);

  final CurriculumStore store;
  final int maxActiveLessons;
  final void Function(String type, Map<String, dynamic> data)? emitEvent;

  static int _levelFromRate(double rate) {
    if (rate >= 0.75) return 2;
    if (rate >= 0.5) return 1;
    return 0;
  }

  /// Bangun/perbarui kurikulum dari pass-rate per skill. Skill dengan
  /// pass-rate < 1 masuk kurikulum, terlemah didahulukan.
  Future<List<CurriculumLesson>> planFromPassRates(
    Map<String, double> passRates,
  ) async {
    await store.load();
    final skills = passRates.keys.toList()..sort();
    for (final skill in skills) {
      final rate = passRates[skill]!.clamp(0.0, 1.0).toDouble();
      if (rate >= 1.0) {
        final done = store.lessons[skill];
        if (done != null && done.status != 'done') {
          done.status = 'done';
          done.level = 3;
          done.lastPassRate = rate;
          done.updatedAt = DateTime.now().toUtc();
        }
        continue;
      }
      final existing = store.lessons[skill];
      final level = _levelFromRate(rate);
      if (existing == null) {
        store.lessons[skill] = CurriculumLesson(
          skill: skill,
          level: level,
          status: 'todo',
          lastPassRate: rate,
        );
      } else {
        existing.level = level;
        existing.lastPassRate = rate;
        if (existing.status == 'done') existing.status = 'active';
        existing.updatedAt = DateTime.now().toUtc();
      }
    }
    await store.save();
    return planned();
  }

  /// Kurikulum aktif diurutkan terlemah dulu (level asc, lalu skill asc).
  List<CurriculumLesson> planned() {
    store.ensureLoadedSync();
    final list = store.lessons.values
        .where((l) => l.status != 'done')
        .toList()
      ..sort((a, b) {
        final byLevel = a.level.compareTo(b.level);
        if (byLevel != 0) return byLevel;
        return a.skill.compareTo(b.skill);
      });
    return list.take(maxActiveLessons).toList();
  }

  /// Latihan berikutnya yang harus dikerjakan (null bila kurikulum kosong).
  CurriculumLesson? next() {
    final plan = planned();
    return plan.isEmpty ? null : plan.first;
  }

  /// Catat hasil latihan; level naik hanya bila lulus (fail-closed terhadap
  /// klaim tanpa bukti). Skill tak dikenal → laporan gagal.
  Future<bool> advance(String skill, {required bool passed}) async {
    await store.load();
    final lesson = store.lessons[skill.trim()];
    if (lesson == null) return false;
    lesson.attempts += 1;
    if (passed) {
      lesson.level = (lesson.level + 1).clamp(0, 3);
      lesson.status = lesson.level >= 3 ? 'done' : 'active';
    } else {
      lesson.status = 'active';
    }
    lesson.updatedAt = DateTime.now().toUtc();
    await store.save();
    emitEvent?.call('curriculum.advanced', {
      'skill': lesson.skill,
      'level': lesson.level,
      'passed': passed,
      'status': lesson.status,
    });
    return true;
  }

  Map<String, dynamic> snapshot() => {
        'total_lessons': store.lessons.length,
        'active': [for (final l in planned()) l.toJson()],
      };
}

/// Tool `curriculum` — kurikulum skill deterministik (selalu terdaftar,
/// risk low): plan dari laporan benchmark, next, advance, list.
class CurriculumTool implements Tool {
  CurriculumTool({required this.curriculum});

  final SkillCurriculum curriculum;

  @override
  ToolSpec get spec => const ToolSpec(
        name: 'curriculum',
        description:
            'Kurikulum latihan skill deterministik (Voyager-style): rencana '
            'dari pass-rate benchmark (skill terlemah dulu), latihan '
            'berikutnya, catat hasil, daftar kurikulum aktif.',
        inputSchema: {
          'type': 'object',
          'properties': {
            'action': {
              'type': 'string',
              'enum': ['plan', 'next', 'advance', 'list'],
            },
            'report': {
              'type': 'string',
              'description':
                  'JSON laporan SkillBenchmark (toJson) untuk action plan.',
            },
            'pass_rates': {
              'type': 'object',
              'description':
                  'Alternatif report: peta skill → pass-rate 0..1 untuk plan.',
            },
            'skill': {'type': 'string', 'description': 'Skill (advance).'},
            'passed': {
              'type': 'boolean',
              'description': 'Hasil latihan lulus atau tidak (advance).',
            },
          },
          'required': ['action'],
        },
        risk: 'low',
        timeoutSec: 30,
      );

  @override
  Future<ToolResult> run(Map<String, dynamic> args, ToolContext ctx) async {
    final action = '${args['action'] ?? ''}'.trim();
    switch (action) {
      case 'plan':
        Map<String, double> rates;
        final reportRaw = '${args['report'] ?? ''}'.trim();
        if (reportRaw.isNotEmpty) {
          try {
            final decoded = jsonDecode(reportRaw);
            if (decoded is! Map) throw const FormatException('bukan object');
            final results = decoded['results'];
            if (results is! List) throw const FormatException('results kosong');
            final bySkill = <String, List<bool>>{};
            for (final r in results) {
              if (r is! Map) continue;
              final slug = '${r['skill'] ?? ''}'.trim();
              if (slug.isEmpty) continue;
              bySkill.putIfAbsent(slug, () => []).add(r['passed'] == true);
            }
            rates = {
              for (final e in bySkill.entries)
                e.key: e.value.where((p) => p).length / e.value.length,
            };
          } on FormatException {
            return const ToolResult(
              callId: '',
              content: 'report bukan JSON laporan benchmark yang valid.',
              isError: true,
            );
          }
        } else if (args['pass_rates'] is Map) {
          rates = {
            for (final e in (args['pass_rates'] as Map).entries)
              if (e.value is num) '${e.key}': (e.value as num).toDouble(),
          };
        } else {
          return const ToolResult(
            callId: '',
            content: 'butuh `report` (JSON benchmark) atau `pass_rates`.',
            isError: true,
          );
        }
        final lessons = await curriculum.planFromPassRates(rates);
        return ToolResult(
          callId: '',
          content: const JsonEncoder.withIndent('  ').convert({
            'planned': [for (final l in lessons) l.toJson()],
          }),
        );
      case 'next':
        final lesson = curriculum.next();
        return ToolResult(
          callId: '',
          content: lesson == null
              ? 'Kurikulum kosong — semua skill done atau belum ada plan.'
              : const JsonEncoder.withIndent('  ').convert(lesson.toJson()),
        );
      case 'advance':
        final skill = '${args['skill'] ?? ''}'.trim();
        if (skill.isEmpty) {
          return const ToolResult(
            callId: '',
            content: 'argumen `skill` wajib untuk advance.',
            isError: true,
          );
        }
        final ok = await curriculum.advance(skill, passed: args['passed'] == true);
        return ToolResult(
          callId: '',
          content: ok
              ? 'Hasil latihan dicatat untuk $skill.'
              : 'skill tidak ada di kurikulum (jalankan plan dulu).',
          isError: !ok,
        );
      case 'list':
        return ToolResult(
          callId: '',
          content: const JsonEncoder.withIndent('  ')
              .convert(curriculum.snapshot()),
        );
      default:
        return const ToolResult(
          callId: '',
          content: 'action tidak dikenal (plan|next|advance|list).',
          isError: true,
        );
    }
  }
}

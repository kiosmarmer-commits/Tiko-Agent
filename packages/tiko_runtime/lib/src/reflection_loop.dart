import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'self_learning_engine.dart';

/// Self-improving learning loop — reflection stage.
///
/// Complements [SelfLearningEngine] (skill synthesis) with a reflection
/// loop modeled after Hermes' closed learning loop and Claude Code's
/// post-task review:
/// 1. After a session (or every N turns), [reflect] inspects the
///    conversation trajectory.
/// 2. Successful multi-step trajectories produce positive lessons
///    ("what worked"); failed turns and error tool calls produce
///    corrective lessons ("what to avoid").
/// 3. Lessons similar to an existing one reinforce it (timesReinforced++)
///    instead of duplicating it.
/// 4. [buildContextPrompt] injects the most relevant lessons into future
///    prompts, closing the loop.

/// One distilled lesson from reflection.
class Lesson {
  Lesson({
    required this.id,
    required this.trigger,
    required this.insight,
    required this.action,
    required this.createdAt,
    this.timesReinforced = 0,
    this.sourceSession,
    this.isSuccessful = true,
  });

  final String id;

  /// What situation triggers this lesson, e.g. "deploy gagal".
  final String trigger;

  /// The distilled insight, e.g. "cek versi SDK sebelum build".
  final String insight;

  /// Concrete next action to take when [trigger] recurs.
  final String action;
  final DateTime createdAt;
  int timesReinforced;
  final String? sourceSession;

  /// True for lessons distilled from successful trajectories.
  final bool isSuccessful;

  Map<String, dynamic> toJson() => {
        'id': id,
        'trigger': trigger,
        'insight': insight,
        'action': action,
        'created_at': createdAt.toUtc().toIso8601String(),
        'times_reinforced': timesReinforced,
        if (sourceSession != null) 'source_session': sourceSession,
        'is_successful': isSuccessful,
      };

  factory Lesson.fromJson(Map<String, dynamic> json) => Lesson(
        id: json['id'] as String? ?? '',
        trigger: json['trigger'] as String? ?? '',
        insight: json['insight'] as String? ?? '',
        action: json['action'] as String? ?? '',
        createdAt: DateTime.tryParse(json['created_at'] as String? ?? '')
                ?.toUtc() ??
            DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
        timesReinforced: json['times_reinforced'] as int? ?? 0,
        sourceSession: json['source_session'] as String?,
        isSuccessful: json['is_successful'] as bool? ?? true,
      );

  String get promptLine => '- Jika: $trigger → Insight: $insight → '
      'Aksi: $action (diperkuat ${1 + timesReinforced}x)';
}

/// Result of one reflection pass.
class ReflectionResult {
  const ReflectionResult({
    required this.newLessons,
    required this.reinforcedIds,
    required this.observations,
  });

  final List<Lesson> newLessons;
  final List<String> reinforcedIds;
  final List<String> observations;

  bool get isEmpty => newLessons.isEmpty && reinforcedIds.isEmpty;
}

/// Configuration for [ReflectionEngine].
class ReflectionConfig {
  const ReflectionConfig({
    this.minTurnsForReflection = 2,
    this.similarityThreshold = 0.6,
    this.maxLessons = 200,
    this.maxLessonsInContext = 5,
    this.maxLessonTextChars = 200,
  });

  final int minTurnsForReflection;
  final double similarityThreshold;
  final int maxLessons;
  final int maxLessonsInContext;
  final int maxLessonTextChars;
}

/// Reflection engine persisting lessons as JSON.
class ReflectionEngine {
  ReflectionEngine({
    required this.storePath,
    this.config = const ReflectionConfig(),
  });

  final String storePath;
  final ReflectionConfig config;
  final List<Lesson> _lessons = [];
  int _seq = 0;

  int get length => _lessons.length;

  List<Lesson> get all => List<Lesson>.unmodifiable(_lessons);

  Future<void> load() async {
    final f = File(storePath);
    if (!await f.exists()) return;
    try {
      final json = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      _seq = json['seq'] as int? ?? 0;
      for (final raw in json['lessons'] as List<dynamic>? ?? []) {
        if (raw is! Map<String, dynamic>) continue;
        _lessons.add(Lesson.fromJson(raw));
      }
    } catch (_) {}
  }

  Future<void> save() async {
    final f = File(storePath);
    await f.parent.create(recursive: true);
    await f.writeAsString(jsonEncode({
      'seq': _seq,
      'lessons': [for (final l in _lessons) l.toJson()],
    }));
  }

  /// Reflects over a session trajectory and updates the lesson store.
  ///
  /// - Failed turns (or turns whose tool calls errored) produce corrective
  ///   lessons built from the failing context.
  /// - Successful multi-tool trajectories produce positive lessons.
  /// - Similar lessons are reinforced instead of duplicated.
  ReflectionResult reflect({
    required List<ConversationTurn> turns,
    required String sessionId,
    DateTime? now,
  }) {
    final at = (now ?? DateTime.now()).toUtc();
    final newLessons = <Lesson>[];
    final reinforced = <String>[];
    final observations = <String>[];

    if (turns.length < config.minTurnsForReflection) {
      return const ReflectionResult(
        newLessons: [],
        reinforcedIds: [],
        observations: ['terlalu sedikit turn untuk refleksi'],
      );
    }

    final failedTurns = turns.where((t) => !t.isSuccessful).toList();
    final successfulTurns =
        turns.where((t) => t.isSuccessful && t.toolCalls.isNotEmpty).toList();

    for (final turn in failedTurns) {
      final trigger = _truncate(turn.userMessage ?? 'tugas tanpa teks');
      final toolsUsed = turn.toolCalls.map((c) => c.name).toSet();
      final insight = toolsUsed.isEmpty
          ? 'tugas sebelumnya gagal pada sesi $sessionId'
          : 'tugas dengan tool ${toolsUsed.join(', ')} gagal pada sesi '
              '$sessionId';
      final action = toolsUsed.isEmpty
          ? 'ulangi dengan langkah lebih kecil dan verifikasi tiap langkah'
          : 'verifikasi argumen tool sebelum memanggil ulang';
      final outcome = _absorb(
        trigger: trigger,
        insight: insight,
        action: action,
        sessionId: sessionId,
        isSuccessful: false,
        now: at,
      );
      if (outcome.isNew) {
        newLessons.add(outcome.lesson);
      } else {
        reinforced.add(outcome.lesson.id);
      }
    }

    if (successfulTurns.length >= config.minTurnsForReflection) {
      final tools = <String>{};
      for (final t in successfulTurns) {
        for (final c in t.toolCalls) {
          tools.add(c.name);
        }
      }
      final goal = _truncate(successfulTurns.last.userMessage ?? 'tugas');
      final outcome = _absorb(
        trigger: goal,
        insight: 'kombinasi tool ${tools.join(', ')} berhasil di sesi '
            '$sessionId',
        action: 'pertimbangkan menjadikan pola ini skill otomatis',
        sessionId: sessionId,
        isSuccessful: true,
        now: at,
      );
      if (outcome.isNew) {
        newLessons.add(outcome.lesson);
      } else {
        reinforced.add(outcome.lesson.id);
      }
    }

    observations.add('${newLessons.length} pelajaran baru, '
        '${reinforced.length} diperkuat');
    return ReflectionResult(
      newLessons: newLessons,
      reinforcedIds: reinforced,
      observations: observations,
    );
  }

  /// Retrieves the most relevant lessons for [query], best first.
  List<Lesson> relevantLessons(String query, {int? k}) {
    final limit = k ?? config.maxLessonsInContext;
    final queryTokens = _tokens(query);
    final scored = <(double, int, Lesson)>[];
    var index = 0;
    for (final lesson in _lessons) {
      final overlap = _overlap(queryTokens,
          '${lesson.trigger} ${lesson.insight}');
      final reinforcement = 1.0 + math.min(lesson.timesReinforced, 10) * 0.1;
      scored.add((overlap * reinforcement, index++, lesson));
    }
    scored.sort((a, b) {
      final byScore = b.$1.compareTo(a.$1);
      if (byScore != 0) return byScore;
      return a.$2.compareTo(b.$2);
    });
    return [
      for (final s in scored.take(limit))
        if (s.$1 > 0) s.$3,
    ];
  }

  /// Builds a prompt block injecting relevant lessons. Empty when nothing
  /// matches, so prompts stay clean.
  String buildContextPrompt(String query) {
    final lessons = relevantLessons(query);
    if (lessons.isEmpty) return '';
    final buffer = StringBuffer('Pelajaran dari pengalaman sebelumnya:\n');
    for (final lesson in lessons) {
      buffer.writeln(lesson.promptLine);
    }
    return buffer.toString().trim();
  }

  ({bool isNew, Lesson lesson}) _absorb({
    required String trigger,
    required String insight,
    required String action,
    required String sessionId,
    required bool isSuccessful,
    required DateTime now,
  }) {
    for (final existing in _lessons) {
      if (_similarity(trigger, existing.trigger) >=
          config.similarityThreshold) {
        existing.timesReinforced++;
        return (isNew: false, lesson: existing);
      }
    }
    final lesson = Lesson(
      id: 'l${_seq++}',
      trigger: trigger,
      insight: _truncate(insight),
      action: _truncate(action),
      createdAt: now,
      sourceSession: sessionId,
      isSuccessful: isSuccessful,
    );
    _lessons.add(lesson);
    while (_lessons.length > config.maxLessons) {
      _lessons.removeAt(0);
    }
    return (isNew: true, lesson: lesson);
  }

  double _similarity(String a, String b) {
    final ta = _tokens(a);
    final tb = _tokens(b);
    if (ta.isEmpty || tb.isEmpty) return 0;
    final inter = ta.where(tb.contains).length;
    final union = ta.length + tb.length - inter;
    return union == 0 ? 0 : inter / union;
  }

  String _truncate(String text) {
    final flat = text.replaceAll('\n', ' ').trim();
    if (flat.length <= config.maxLessonTextChars) return flat;
    return '${flat.substring(0, config.maxLessonTextChars - 3)}...';
  }

  static Set<String> _tokens(String text) => text
      .toLowerCase()
      .split(RegExp(r'[^a-z0-9]+'))
      .where((t) => t.isNotEmpty)
      .toSet();

  static double _overlap(Set<String> queryTokens, String text) {
    if (queryTokens.isEmpty) return 0;
    final textTokens = _tokens(text);
    if (textTokens.isEmpty) return 0;
    return queryTokens.where(textTokens.contains).length / queryTokens.length;
  }
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:agent_core/agent_core.dart';
import 'package:path/path.dart' as p;

import 'event_bus.dart';
import 'reflection_loop.dart';

/// Deterministic, always-available reward for one task trajectory (B4).
///
/// Weights: outcome success 0.6, tool cleanliness 0.25, user feedback 0.15.
/// Missing feedback counts as neutral (0.5) so unfeedbacked turns are not
/// punished; explicit negative feedback still drags the reward down and, when
/// it contradicts `success`, marks the record ambiguous for LLM judging.
double computeDeterministicReward({
  required bool success,
  required int errorCount,
  required int toolCalls,
  bool? feedback,
}) {
  final errorRatio =
      toolCalls == 0 ? 0.0 : (errorCount / toolCalls).clamp(0.0, 1.0);
  final feedbackScore = feedback == null ? 0.5 : (feedback ? 1.0 : 0.0);
  return 0.6 * (success ? 1.0 : 0.0) +
      0.25 * (1.0 - errorRatio) +
      0.15 * feedbackScore;
}

/// One observed task trajectory in the self-evolution ledger (B4).
class TrajectoryRecord {
  TrajectoryRecord({
    required this.id,
    required this.createdAt,
    required this.sessionId,
    required this.success,
    this.task = '',
    this.skillSlug,
    this.toolCalls = const [],
    this.errorCount = 0,
    this.feedback,
    double? deterministicReward,
    this.judgeScore,
    this.judgeReason,
  }) : deterministicReward = deterministicReward ??
            computeDeterministicReward(
              success: success,
              errorCount: errorCount,
              toolCalls: toolCalls.length,
              feedback: feedback,
            );

  final String id;
  final DateTime createdAt;
  final String sessionId;
  final bool success;

  /// First 200 chars of the user request, for LLM judge context.
  final String task;
  final String? skillSlug;
  final List<String> toolCalls;
  final int errorCount;

  /// Explicit user feedback (👍/👎) when the host routed it back.
  bool? feedback;
  double deterministicReward;
  double? judgeScore;
  String? judgeReason;

  /// True when deterministic success contradicts explicit user feedback —
  /// exactly the cases an LLM judge must arbitrate.
  bool get isAmbiguous => feedback != null && feedback != success;

  /// Blended reward: deterministic when unjudged, 50/50 blend when the LLM
  /// judge has scored the trajectory.
  double get reward => judgeScore == null
      ? deterministicReward
      : 0.5 * deterministicReward + 0.5 * judgeScore!;

  /// Applies late user feedback (C1): re-blends the deterministic reward so
  /// bandit statistics and quarantine see the human signal.
  void applyFeedback(bool positive) {
    feedback = positive;
    deterministicReward = computeDeterministicReward(
      success: success,
      errorCount: errorCount,
      toolCalls: toolCalls.length,
      feedback: positive,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'at': createdAt.toIso8601String(),
        'session': sessionId,
        'success': success,
        'task': task,
        if (skillSlug != null) 'skill': skillSlug,
        'tools': toolCalls,
        'errors': errorCount,
        if (feedback != null) 'feedback': feedback,
        'det': deterministicReward,
        if (judgeScore != null) 'judge': judgeScore,
        if (judgeReason != null) 'judge_reason': judgeReason,
      };

  factory TrajectoryRecord.fromJson(Map<String, dynamic> json) =>
      TrajectoryRecord(
        id: json['id'] as String? ?? '',
        createdAt:
            DateTime.tryParse(json['at'] as String? ?? '') ?? DateTime.now(),
        sessionId: json['session'] as String? ?? '',
        success: json['success'] as bool? ?? false,
        task: json['task'] as String? ?? '',
        skillSlug: json['skill'] as String?,
        toolCalls: [
          for (final t in json['tools'] as List<dynamic>? ?? [])
            if (t is String) t,
        ],
        errorCount: json['errors'] as int? ?? 0,
        feedback: json['feedback'] as bool?,
        deterministicReward: (json['det'] as num?)?.toDouble(),
        judgeScore: (json['judge'] as num?)?.toDouble(),
        judgeReason: json['judge_reason'] as String?,
      );
}

/// Capped JSONL store of [TrajectoryRecord]s. Appends line-by-line and only
/// rewrites the file when the cap is exceeded, so the hot path stays cheap.
/// With `autoPersist: false` records buffer in memory until [flush] — used by
/// [SelfEvolutionEngine] so per-turn bookkeeping does no disk I/O and cannot
/// race a host shutting down.
class TrajectoryLedger {
  TrajectoryLedger({
    required this.path,
    this.maxRecords = 2000,
    this.autoPersist = true,
  }) {
    _load();
  }

  final String path;
  final int maxRecords;
  final bool autoPersist;
  final List<TrajectoryRecord> _pending = [];
  final List<TrajectoryRecord> _records = [];

  int get length => _records.length;
  List<TrajectoryRecord> get records => List.unmodifiable(_records);

  void _load() {
    try {
      final f = File(path);
      if (!f.existsSync()) return;
      for (final line in f.readAsLinesSync()) {
        final trimmed = line.trim();
        if (trimmed.isEmpty) continue;
        try {
          _records.add(
            TrajectoryRecord.fromJson(jsonDecode(trimmed) as Map<String, dynamic>),
          );
        } catch (_) {
          // Skip malformed lines; a torn JSONL tail must not break startup.
        }
      }
      if (_records.length > maxRecords) {
        _records.removeRange(0, _records.length - maxRecords);
      }
    } catch (_) {
      // Ledger load is best-effort; evolution still runs from an empty ledger.
    }
  }

  Future<void> add(TrajectoryRecord record) async {
    _records.add(record);
    _pending.add(record);
    if (_records.length > maxRecords) {
      _records.removeRange(0, _records.length - maxRecords);
      _pending.clear();
      await _rewrite();
    } else if (autoPersist) {
      await _appendPending();
    }
  }

  /// Persists buffered records (deferred mode). No-op when empty.
  Future<void> flush() async {
    if (_records.length > maxRecords) {
      _records.removeRange(0, _records.length - maxRecords);
      _pending.clear();
      await _rewrite();
      return;
    }
    await _appendPending();
  }

  Future<void> _appendPending() async {
    if (_pending.isEmpty) return;
    final f = File(path);
    await f.parent.create(recursive: true);
    await f.writeAsString(
      '${_pending.map((r) => jsonEncode(r.toJson())).join('\n')}\n',
      mode: FileMode.append,
    );
    _pending.clear();
  }

  Future<void> _rewrite() async {
    final f = File(path);
    await f.parent.create(recursive: true);
    final tmp = File('$path.tmp');
    await tmp.writeAsString(
      '${_records.map((r) => jsonEncode(r.toJson())).join('\n')}\n',
    );
    await tmp.rename(path);
    _pending.clear();
  }

  /// Applies user feedback to the most recent record of [sessionId] and
  /// rewrites the file so the updated reward survives restart (C1). Returns
  /// the updated record, or null when the session has no trajectory.
  Future<TrajectoryRecord?> attachFeedback(
    String sessionId,
    bool positive,
  ) async {
    TrajectoryRecord? target;
    for (final r in _records.reversed) {
      if (r.sessionId == sessionId) {
        target = r;
        break;
      }
    }
    if (target == null) return null;
    target.applyFeedback(positive);
    await _rewrite();
    return target;
  }
}

/// Configuration for the [SelfEvolutionEngine].
class EvolutionConfig {
  const EvolutionConfig({
    this.enabled = true,
    this.consolidationInterval = const Duration(hours: 1),
    this.ledgerMaxRecords = 2000,
    this.maxJudgePerDay = 20,
    this.maxQuarantinesPerDay = 3,
    this.collapseMinSamples = 5,
    this.collapseThreshold = 0.2,
    this.ucbExploration = 1.414,
  });

  final bool enabled;
  final Duration consolidationInterval;

  /// Cap on persisted trajectory records (oldest dropped first).
  final int ledgerMaxRecords;

  /// Cost cap: at most this many LLM judge calls per UTC day.
  final int maxJudgePerDay;

  /// Cost cap: at most this many skill quarantines per UTC day.
  final int maxQuarantinesPerDay;

  /// Minimum samples before a skill's mean reward is trusted.
  final int collapseMinSamples;

  /// Mean blended reward below which a skill is quarantined to draft.
  final double collapseThreshold;
  final double ucbExploration;
}

/// LLM-as-judge reward model with a hard daily budget (B4). Only ambiguous
/// trajectories (success contradicted by explicit user feedback) are judged,
/// so the deterministic signal stays the default and cost stays bounded.
class SelfRewardJudge {
  SelfRewardJudge({required this.llmProvider, this.maxPerDay = 20});

  final LlmProvider llmProvider;
  final int maxPerDay;
  int _usedToday = 0;
  String _day = '';

  bool get hasBudget {
    _rollDay();
    return _usedToday < maxPerDay;
  }

  /// Aligns the in-process budget with the persisted cross-process count.
  void setUsedToday(int used) {
    _rollDay();
    _usedToday = used;
  }

  void _rollDay() {
    final day = DateTime.now().toUtc().toIso8601String().substring(0, 10);
    if (day != _day) {
      _day = day;
      _usedToday = 0;
    }
  }

  /// Returns (score, reason) or null when the model output is unusable.
  Future<(double, String)?> judge(TrajectoryRecord record) async {
    if (!hasBudget) return null;
    final verdict = await _ask(record);
    if (verdict == null) return null;
    _usedToday++;
    return verdict;
  }

  Future<(double, String)?> _ask(TrajectoryRecord record) async {
    final request = ChatRequest(
      messages: [
        const ChatMessage(
          role: 'system',
          content: '''
You are a strict reward judge for an autonomous agent. Given one task
trajectory, estimate how well the task was actually accomplished.

Rules:
1. Output exactly two lines:
   SCORE: <number between 0.00 and 1.00>
   REASON: <one concise sentence>
2. Judge outcome quality, not effort. A task that "succeeded" while
   producing wrong or empty output scores low.
3. Never output anything else.
''',
        ),
        ChatMessage(role: 'user', content: _buildPrompt(record)),
      ],
      stream: false,
      temperature: 0.0,
    );
    final response = await llmProvider.chat(request).first;
    if (response is! LlmTextDelta) return null;
    return parseVerdict(response.delta);
  }

  String _buildPrompt(TrajectoryRecord record) {
    return '''
Task: ${record.task.isEmpty ? '(tanpa teks)' : record.task}
Tools used: ${record.toolCalls.isEmpty ? '(tidak ada)' : record.toolCalls.join(', ')}
Tool errors: ${record.errorCount}
Reported success: ${record.success ? 'yes' : 'no'}
User feedback: ${record.feedback == null ? 'none' : (record.feedback! ? 'positive' : 'negative')}
''';
  }

  /// Strict parser: anything without a valid `SCORE:` line is rejected.
  static (double, String)? parseVerdict(String text) {
    final score = RegExp(r'SCORE:\s*([0-9]+(?:\.[0-9]+)?)').firstMatch(text);
    if (score == null) return null;
    final value = double.tryParse(score.group(1)!);
    if (value == null || value < 0 || value > 1) return null;
    final reason =
        RegExp(r'REASON:\s*(.+)').firstMatch(text)?.group(1)?.trim() ?? '';
    return (value.clamp(0.0, 1.0).toDouble(), reason);
  }
}

/// UCB1 bandit statistics for one skill (B4).
class SkillBanditStats {
  SkillBanditStats();

  int count = 0;
  double _sum = 0;

  void observe(double reward) {
    count++;
    _sum += reward;
  }

  double get mean => count == 0 ? 0 : _sum / count;

  /// UCB1 score; untried skills score infinity so exploration is guaranteed.
  double ucb(int totalRounds, double exploration) {
    if (count == 0) return double.infinity;
    return mean + exploration * math.sqrt(math.log(totalRounds + 1) / count);
  }

  Map<String, dynamic> toJson() => {'count': count, 'sum': _sum};

  factory SkillBanditStats.fromJson(Map<String, dynamic> json) =>
      SkillBanditStats._(
        count: json['count'] as int? ?? 0,
        sum: (json['sum'] as num?)?.toDouble() ?? 0,
      );

  SkillBanditStats._({required this.count, required double sum}) : _sum = sum;
}

/// Self-evolution engine (B4): consolidates the trajectory ledger into
/// blended rewards, arbitrates ambiguous outcomes with a budgeted LLM judge,
/// and quarantines skills whose measured reward has collapsed — the runtime
/// equivalent of GEPA-style reflective prompt/skill evolution.
///
/// Design contract:
/// - The deterministic reward is always available; the LLM judge is optional
///   and budget-capped, so the loop keeps working offline.
/// - Quarantine is conservative: minimum samples, hard daily caps, and
///   recovery through the existing skill approval flow.
/// - Failures never propagate: callers wrap [recordTurn] best-effort and
///   [consolidate] swallows its own errors.
class SelfEvolutionEngine {
  SelfEvolutionEngine({
    required this.dataDir,
    this.llmProvider,
    this.skills,
    this.reflectionEngine,
    EventBus? events,
    this.config = const EvolutionConfig(),
  })  : _events = events,
        _judge = llmProvider == null
            ? null
            : SelfRewardJudge(
                llmProvider: llmProvider,
                maxPerDay: config.maxJudgePerDay,
              ),
        _ledger = TrajectoryLedger(
          path: p.join(dataDir, 'evolution', 'ledger.jsonl'),
          maxRecords: config.ledgerMaxRecords,
          autoPersist: false,
        ) {
    _loadState();
  }

  final String dataDir;
  final LlmProvider? llmProvider;
  final SkillRegistry? skills;
  final ReflectionEngine? reflectionEngine;
  final EventBus? _events;
  final EvolutionConfig config;

  final TrajectoryLedger _ledger;
  final SelfRewardJudge? _judge;
  final Map<String, SkillBanditStats> _bandits = {};
  final Map<String, int> _judgeUsedByDay = {};
  final Map<String, int> _quarantinedByDay = {};
  int _totalRounds = 0;
  Timer? _timer;
  bool _consolidating = false;

  TrajectoryLedger get ledger => _ledger;
  Map<String, SkillBanditStats> get bandits => _bandits;

  String _todayKey() =>
      DateTime.now().toUtc().toIso8601String().substring(0, 10);

  void _loadState() {
    try {
      final f = File(p.join(dataDir, 'evolution', 'state.json'));
      if (!f.existsSync()) return;
      final json = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      _totalRounds = json['total_rounds'] as int? ?? 0;
      for (final e in (json['judge_used'] as Map<String, dynamic>? ?? {}).entries) {
        _judgeUsedByDay[e.key] = e.value as int? ?? 0;
      }
      for (final e
          in (json['quarantined'] as Map<String, dynamic>? ?? {}).entries) {
        _quarantinedByDay[e.key] = e.value as int? ?? 0;
      }
      for (final e in (json['bandits'] as Map<String, dynamic>? ?? {}).entries) {
        if (e.value is! Map<String, dynamic>) continue;
        _bandits[e.key] = SkillBanditStats.fromJson(e.value as Map<String, dynamic>);
      }
      _judge?.setUsedToday(_judgeUsedByDay[_todayKey()] ?? 0);
    } catch (_) {
      // State load is best-effort; a corrupt state file resets counters only.
    }
  }

  void _saveState() {
    try {
      final dir = Directory(p.join(dataDir, 'evolution'));
      if (!dir.existsSync()) dir.createSync(recursive: true);
      final f = File(p.join(dataDir, 'evolution', 'state.json'));
      final tmp = File('${f.path}.tmp');
      tmp.writeAsStringSync(jsonEncode({
        'total_rounds': _totalRounds,
        'judge_used': _judgeUsedByDay,
        'quarantined': _quarantinedByDay,
        'bandits': {
          for (final e in _bandits.entries) e.key: e.value.toJson(),
        },
      }));
      tmp.renameSync(f.path);
    } catch (_) {
      // State persistence is best-effort; the ledger remains the source of
      // truth and bandits are recomputed on the next consolidation.
    }
  }

  /// Persists buffered trajectory records. Called by [consolidate] and
  /// [stop]; exposed for hosts that want durability on demand.
  Future<void> flush() => _ledger.flush();

  /// Routes turn-level user feedback into the ledger (C1): updates the
  /// latest trajectory of [sessionId], re-blends its reward, and emits
  /// `evolution.feedback`. Returns false when the session has no record.
  Future<bool> recordFeedback({
    required String sessionId,
    required bool positive,
  }) async {
    if (!config.enabled) return false;
    final record = await _ledger.attachFeedback(sessionId, positive);
    if (record == null) return false;
    _events?.emit('evolution.feedback', {
      'session': sessionId,
      'positive': positive,
      'skill': record.skillSlug,
      'reward': record.reward,
    });
    return true;
  }

  /// Records one finished task trajectory. Buffered in memory and persisted
  /// on the next consolidation/stop, so the per-turn hot path does no disk
  /// I/O. Called best-effort after every chat turn; must never throw into
  /// the caller.
  Future<void> recordTurn({
    required String sessionId,
    required bool success,
    List<String> toolNames = const [],
    int errorCount = 0,
    bool? feedback,
    String? skillSlug,
    String task = '',
  }) async {
    if (!config.enabled) return;
    final record = TrajectoryRecord(
      id: 'tr${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}',
      createdAt: DateTime.now().toUtc(),
      sessionId: sessionId,
      success: success,
      task: task.length > 200 ? task.substring(0, 200) : task,
      skillSlug: skillSlug,
      toolCalls: List.of(toolNames),
      errorCount: errorCount,
      feedback: feedback,
      deterministicReward: computeDeterministicReward(
        success: success,
        errorCount: errorCount,
        toolCalls: toolNames.length,
        feedback: feedback,
      ),
    );
    await _ledger.add(record);
  }

  /// Starts the periodic consolidation loop. Idempotent.
  void start() {
    if (!config.enabled || _timer != null) return;
    _timer = Timer.periodic(config.consolidationInterval, (_) {
      unawaited(consolidate());
    });
  }

  /// Stops the loop and persists counters and buffered records. Idempotent.
  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    try {
      await _ledger.flush();
    } catch (_) {
      // Ledger flush is best-effort; state counters still get saved below.
    }
    _saveState();
  }

  /// One consolidation pass: judge ambiguous records (budget-capped),
  /// recompute bandit statistics, quarantine collapsed skills, persist state,
  /// and emit a summary event. Safe to call manually (tests/CLI) and idempotent
  /// while a pass is already running.
  Future<void> consolidate() async {
    if (!config.enabled || _consolidating) return;
    _consolidating = true;
    try {
      final day = _todayKey();
      var judged = 0;
      final judge = _judge;
      if (judge != null) {
        final budget = config.maxJudgePerDay - (_judgeUsedByDay[day] ?? 0);
        for (final r in _ledger.records) {
          if (judged >= budget) break;
          if (!r.isAmbiguous || r.judgeScore != null) continue;
          final verdict = await judge.judge(r);
          if (verdict == null) break;
          r.judgeScore = verdict.$1;
          r.judgeReason = verdict.$2;
          judged++;
        }
        if (judged > 0) {
          _judgeUsedByDay[day] = (_judgeUsedByDay[day] ?? 0) + judged;
          judge.setUsedToday(_judgeUsedByDay[day]!);
        }
      }
      _recomputeBandits();
      final quarantined = _quarantineCollapsed(day);
      await _ledger.flush();
      _saveState();
      _events?.emit('evolution.consolidated', {
        'judged': judged,
        'quarantined': quarantined,
        'records': _ledger.length,
        'skills_tracked': _bandits.length,
      });
    } finally {
      _consolidating = false;
    }
  }

  void _recomputeBandits() {
    _bandits.clear();
    _totalRounds = 0;
    for (final r in _ledger.records) {
      final slug = r.skillSlug;
      if (slug == null) continue;
      _totalRounds++;
      _bandits.putIfAbsent(slug, SkillBanditStats.new).observe(r.reward);
    }
  }

  int _quarantineCollapsed(String day) {
    final registry = skills;
    if (registry == null) return 0;
    var quarantined = 0;
    for (final slug in _bandits.keys.toList()) {
      if (quarantined >= config.maxQuarantinesPerDay) break;
      if ((_quarantinedByDay[day] ?? 0) >= config.maxQuarantinesPerDay) break;
      final stats = _bandits[slug]!;
      if (stats.count < config.collapseMinSamples) continue;
      if (stats.mean >= config.collapseThreshold) continue;
      final skill = registry.get(slug);
      if (skill == null) continue;
      if (skill.status == SkillStatus.draft ||
          skill.status == SkillStatus.retired) {
        continue;
      }
      skill.status = SkillStatus.draft;
      skill.approvedBy = null;
      _quarantinedByDay[day] = (_quarantinedByDay[day] ?? 0) + 1;
      quarantined++;
      reflectionEngine?.recordCorrectiveLesson(
        trigger: 'skill $slug gagal berulang',
        insight: 'skill $slug memiliki reward rata-rata '
            '${stats.mean.toStringAsFixed(2)} dari ${stats.count} pemakaian',
        action: 'perbaiki atau tulis ulang skill sebelum dipromosikan ulang',
        sessionId: 'evolution',
      );
      _events?.emit('evolution.quarantined', {
        'slug': slug,
        'mean': stats.mean,
        'samples': stats.count,
      });
    }
    return quarantined;
  }

  /// UCB1 selection over tracked skills: highest optimistic reward first.
  /// Untried skills win so exploration is guaranteed. Null when nothing is
  /// tracked yet.
  String? selectSkill() {
    _recomputeBandits();
    String? bestSlug;
    double? bestScore;
    for (final entry in _bandits.entries) {
      final score = entry.value.ucb(_totalRounds, config.ucbExploration);
      if (bestScore == null || score > bestScore) {
        bestScore = score;
        bestSlug = entry.key;
      }
    }
    return bestSlug;
  }
}

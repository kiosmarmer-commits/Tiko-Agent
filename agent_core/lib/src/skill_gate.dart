import 'dart:convert';
import 'dart:math' as math;
import 'dart:io';

import 'golden.dart';
import 'skill_scanner.dart';
import 'skills.dart';

/// Promotion pipeline: draft → scanned → evaluated → canary/trial → approved
/// (PRD §9.5). Golden tasks must run in a real isolated runtime harness.
typedef GoldenTaskEvaluator = Future<List<GoldenResult>> Function(List<GoldenTask> tasks);

class SkillGateResult {
  SkillGateResult({
    required this.ok,
    required this.slug,
    required this.stage,
    this.findings = const [],
    this.goldenScore = 0,
    this.goldenTotal = 0,
    this.message = '',
  });

  final bool ok;
  final String slug;
  final String stage;
  final List<String> findings;
  final double goldenScore;
  final double goldenTotal;
  final String message;

  Map<String, dynamic> toJson() => {
        'ok': ok,
        'slug': slug,
        'stage': stage,
        'findings': findings,
        'golden_score': goldenScore,
        'golden_total': goldenTotal,
        'message': message,
      };
}

class SkillPromotionGate {
  SkillPromotionGate({
    this.skillsDir = 'skills',
    this.goldenDir = 'test/golden',
    this.minGoldenRatio = 0.8,
    this.evaluator,
  }) {
    if (!minGoldenRatio.isFinite || minGoldenRatio <= 0 || minGoldenRatio > 1) {
      throw ArgumentError.value(minGoldenRatio, 'minGoldenRatio', 'must be > 0 and <= 1');
    }
  }

  final String skillsDir;
  final String goldenDir;
  final double minGoldenRatio;
  final GoldenTaskEvaluator? evaluator;
  final Map<String, String> _passedEvaluationFingerprints = {};

  /// Full gate: scan → optional golden file for slug → set status.
  Future<SkillGateResult> evaluateAndMaybePromote(
    Skill skill, {
    bool promoteOnPass = false,
    List<GoldenTask>? tasks,
  }) async {
    _passedEvaluationFingerprints.remove(skill.slug);
    // 1) Static scan
    final scanPath = skill.path ?? '$skillsDir/${skill.slug}';
    final scan = Directory(scanPath).existsSync()
        ? SkillScanner.scanDirectory(scanPath)
        : (skill.path != null
            ? SkillScanner.scanFile(skill.path!)
            : SkillScanner.scanContent('${skill.description}\n${skill.body}'));

    if (!scan.ok) {
      skill.status = SkillStatus.draft;
      return SkillGateResult(
        ok: false,
        slug: skill.slug,
        stage: 'scan',
        findings: scan.findings,
        message: 'static scan failed — not promoted',
      );
    }

    // 2) Golden evaluation
    var loaded = tasks;
    if (loaded == null) {
      final specific = File('$goldenDir/${skill.slug}.yaml');
      final general = File('$goldenDir/skills_smoke.yaml');
      if (await specific.exists()) {
        loaded = loadGoldenYaml(specific.path);
      } else if (await general.exists()) {
        loaded = loadGoldenYaml(general.path);
      } else {
        loaded = [
          GoldenTask(
            id: 'skill-smoke-${skill.slug}',
            input: skill.triggers.isNotEmpty
                ? skill.triggers.first
                : skill.name,
            answerContains: skill.name.split(' ').take(1).toList(),
            weight: 1,
          ),
        ];
      }
    }

    if (loaded.isEmpty || loaded.length > 500) {
      skill.status = SkillStatus.draft;
      return SkillGateResult(
        ok: false,
        slug: skill.slug,
        stage: 'golden_invalid',
        findings: const ['golden task set must contain 1..500 tasks'],
        message: 'promotion blocked: invalid golden task set',
      );
    }
    final ids = <String>{};
    for (final task in loaded) {
      if (task.id.trim().isEmpty || !ids.add(task.id) ||
          task.input.trim().isEmpty || !task.weight.isFinite ||
          task.weight <= 0 || task.weight > 100) {
        skill.status = SkillStatus.draft;
        return SkillGateResult(
          ok: false,
          slug: skill.slug,
          stage: 'golden_invalid',
          findings: ['invalid or duplicate golden task: ${task.id}'],
          message: 'promotion blocked: invalid golden task set',
        );
      }
    }

    // Never treat words copied from the skill file as proof that the skill
    // works. Without an actual isolated AgentLoop evaluator, fail closed.
    final runGolden = evaluator;
    if (runGolden == null) {
      skill.goldenScore = 0;
      skill.goldenTotal = loaded.fold<double>(0, (sum, task) => sum + task.weight);
      skill.status = SkillStatus.draft;
      return SkillGateResult(
        ok: false,
        slug: skill.slug,
        stage: 'golden_runtime_unavailable',
        findings: const ['real AgentLoop/sandbox evaluator is not configured'],
        goldenScore: 0,
        goldenTotal: skill.goldenTotal,
        message: 'promotion blocked: text-only checks are not an execution test',
      );
    }

    final List<GoldenResult> results;
    try {
      results = await runGolden(loaded);
    } catch (error) {
      skill.goldenScore = 0;
      skill.goldenTotal = loaded.fold<double>(0, (sum, task) => sum + task.weight);
      skill.status = SkillStatus.draft;
      _passedEvaluationFingerprints.remove(skill.slug);
      return SkillGateResult(
        ok: false,
        slug: skill.slug,
        stage: 'golden_execution_error',
        findings: ['isolated evaluator failed: $error'],
        goldenTotal: skill.goldenTotal,
        message: 'promotion blocked: golden evaluation did not complete',
      );
    }
    final byId = <String, GoldenResult>{};
    for (final result in results) {
      if (!ids.contains(result.taskId) || byId.containsKey(result.taskId)) {
        skill.status = SkillStatus.draft;
        _passedEvaluationFingerprints.remove(skill.slug);
        return SkillGateResult(
          ok: false,
          slug: skill.slug,
          stage: 'golden_invalid_results',
          findings: ['unexpected or duplicate result id: ${result.taskId}'],
          message: 'promotion blocked: evaluator returned invalid results',
        );
      }
      byId[result.taskId] = result;
    }
    var score = 0.0;
    var total = 0.0;
    final details = <String>[];
    for (final task in loaded) {
      total += task.weight;
      final result = byId[task.id];
      if (result != null && result.passed) {
        score += task.weight;
      } else {
        details.add('${task.id}: ${result?.detail ?? 'no execution result'}');
      }
    }
    final ratio = total <= 0 ? 0.0 : score / total;
    skill.goldenScore = score;
    skill.goldenTotal = total;

    if (ratio < minGoldenRatio || byId.length != loaded.length) {
      _passedEvaluationFingerprints.remove(skill.slug);
      skill.status = SkillStatus.draft;
      return SkillGateResult(
        ok: false,
        slug: skill.slug,
        stage: 'golden',
        findings: details,
        goldenScore: score,
        goldenTotal: total,
        message: 'golden ratio ${ratio.toStringAsFixed(2)} < $minGoldenRatio — blocked',
      );
    }

    _passedEvaluationFingerprints[skill.slug] = _fingerprint(skill);
    if (promoteOnPass) {
      skill.status = SkillStatus.trial; // canary
      return SkillGateResult(
        ok: true,
        slug: skill.slug,
        stage: 'canary',
        goldenScore: score,
        goldenTotal: total,
        message: 'promoted to trial/canary — needs manual approve for production',
      );
    }

    return SkillGateResult(
      ok: true,
      slug: skill.slug,
      stage: 'evaluated',
      goldenScore: score,
      goldenTotal: total,
      message: 'passed scan+golden — call approve to activate',
    );
  }

  /// Force approved only after evaluate ok + explicit actor.
  SkillGateResult approve(Skill skill, {required String actor}) {
    final passedFingerprint = _passedEvaluationFingerprints[skill.slug];
    if (passedFingerprint == null || passedFingerprint != _fingerprint(skill) ||
        skill.goldenTotal <= 0 || !skill.goldenTotal.isFinite ||
        !skill.goldenScore.isFinite ||
        (skill.goldenScore / skill.goldenTotal) < minGoldenRatio) {
      return SkillGateResult(
        ok: false,
        slug: skill.slug,
        stage: 'approve',
        message: 'refuse approve: run evaluate first and pass golden',
      );
    }
    if (actor.trim().isEmpty || actor.length > 128) {
      return SkillGateResult(
        ok: false,
        slug: skill.slug,
        stage: 'approve',
        message: 'refuse approve: explicit valid actor is required',
      );
    }
    skill.status = SkillStatus.approved;
    skill.approvedBy = actor.trim();
    return SkillGateResult(
      ok: true,
      slug: skill.slug,
      stage: 'approved',
      goldenScore: skill.goldenScore,
      goldenTotal: skill.goldenTotal,
      message: 'approved by $actor',
    );
  }

  String _fingerprint(Skill skill) => jsonEncode([
        skill.slug,
        skill.name,
        skill.description,
        skill.body,
        skill.triggers,
        skill.tools,
        skill.version,
        skill.path,
        skill.sha256,
        skill.goldenScore,
        skill.goldenTotal,
      ]);

  SkillGateResult rollback(Skill skill, {String to = 'draft'}) {
    _passedEvaluationFingerprints.remove(skill.slug);
    skill.status = SkillStatus.values.firstWhere(
      (s) => s.name == to,
      orElse: () => SkillStatus.draft,
    );
    return SkillGateResult(
      ok: true,
      slug: skill.slug,
      stage: 'rollback',
      message: 'rolled back to ${skill.status.name}',
    );
  }
}

/// FR-01 (skill gating): Score_gate = α·cos(prompt, skill) +
/// (1−α)·(successRate × ageDecay), α = 0.7 (PRD formula).
///
/// Cosine similarity uses a pluggable embedder. When none is supplied the
/// scorer falls back to lexical Jaccard similarity over token sets so the
/// gate keeps working with zero external dependencies.
class SkillMatchScorer {
  SkillMatchScorer({
    this.alpha = 0.7,
    this.ageHalfLifeDays = 30,
    this.embedder,
  }) : assert(alpha >= 0 && alpha <= 1);

  /// Weight of semantic similarity vs. historical reliability.
  final double alpha;

  /// Skills lose half of their reliability weight every 30 days unused.
  final double ageHalfLifeDays;

  /// Optional async embedding function (e.g. local vector model).
  final Future<List<double>> Function(String text)? embedder;

  /// Ranks [skills] against [prompt]; higher is better. Never throws:
  /// broken skills score 0 and sink in the ranking.
  Future<List<ScoredSkill>> rank(
    String prompt,
    Iterable<Skill> skills, {
    int topK = 5,
  }) async {
    final scored = <ScoredSkill>[];
    for (final s in skills) {
      final score = await scoreOf(prompt, s);
      scored.add(ScoredSkill(skill: s, score: score));
    }
    scored.sort((a, b) => b.score.compareTo(a.score));
    return scored.take(topK).toList();
  }

  Future<double> scoreOf(String prompt, Skill skill) async {
    try {
      final cos = await _closeness(prompt, skill.description);
      final reliability = _reliability(skill);
      final s = alpha * cos + (1 - alpha) * reliability;
      return s.clamp(0.0, 1.0);
    } catch (_) {
      return 0.0;
    }
  }

  Future<double> _closeness(String prompt, String description) async {
    final emb = embedder;
    if (emb != null) {
      final a = await emb(prompt);
      final b = await emb(description);
      return _cosine(a, b);
    }
    return _jaccard(prompt, description);
  }

  double _reliability(Skill skill) {
    var r = skill.successRate;
    final path = skill.path;
    if (path != null) {
      try {
        final age = DateTime.now()
            .difference(File(path).lastModifiedSync())
            .inDays
            .toDouble();
        if (age > 0) {
          final decay = math.pow(0.5, age / ageHalfLifeDays).toDouble();
          r *= decay;
        }
      } catch (_) {
        // Missing file: keep raw success rate.
      }
    }
    return r.clamp(0.0, 1.0);
  }

  double _cosine(List<double> a, List<double> b) {
    if (a.isEmpty || b.isEmpty || a.length != b.length) return 0;
    var dot = 0.0, na = 0.0, nb = 0.0;
    for (var i = 0; i < a.length; i++) {
      dot += a[i] * b[i];
      na += a[i] * a[i];
      nb += b[i] * b[i];
    }
    if (na == 0 || nb == 0) return 0;
    return dot / (math.sqrt(na) * math.sqrt(nb));
  }

  double _jaccard(String a, String b) {
    final ta = _tokens(a), tb = _tokens(b);
    if (ta.isEmpty || tb.isEmpty) return 0;
    final inter = ta.intersection(tb).length;
    final union = ta.union(tb).length;
    return union == 0 ? 0 : inter / union;
  }

  Set<String> _tokens(String s) => s
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9\s]'), ' ')
      .split(RegExp(r'\s+'))
      .where((t) => t.length > 2)
      .toSet();
}

class ScoredSkill {
  ScoredSkill({required this.skill, required this.score});
  final Skill skill;
  final double score;
}

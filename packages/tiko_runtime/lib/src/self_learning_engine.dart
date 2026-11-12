import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:agent_core/agent_core.dart';
import 'package:path/path.dart' as p;

/// Represents a single turn in a conversation.
/// Used internally by the self-learning engine to track conversation state.
class ConversationTurn {
  const ConversationTurn({
    this.userMessage,
    this.assistantMessage,
    this.isSuccessful = true,
    this.toolCalls = const [],
    this.tokensUsed = 0,
    this.timestamp,
  });

  final String? userMessage;
  final String? assistantMessage;
  final bool isSuccessful;
  final List<ToolCall> toolCalls;
  final int tokensUsed;
  final DateTime? timestamp;
}

/// Configuration for the self-learning engine.
class SelfLearningConfig {
  const SelfLearningConfig({
    this.autoCreateEnabled = true,
    this.autoImproveEnabled = true,
    this.nudgeEnabled = true,
    this.synthesisThreshold = 0.85,
    this.minToolCallsForSynthesis = 2,
    this.maxSkillsPerSession = 5,
    this.nudgeInterval = const Duration(hours: 1),
    this.improvementInterval = const Duration(days: 1),
    this.skillsDirectory = 'skills',
    this.maxImprovementsPerCycle = 3,
    this.maxImprovementsPerDay = 12,
  });

  final bool autoCreateEnabled;
  final bool autoImproveEnabled;
  final bool nudgeEnabled;
  final double synthesisThreshold;
  final int minToolCallsForSynthesis;
  final int maxSkillsPerSession;
  final Duration nudgeInterval;
  final Duration improvementInterval;
  final String skillsDirectory;

  /// Cost cap: at most this many LLM-backed skill improvements per cycle.
  final int maxImprovementsPerCycle;

  /// Cost cap: at most this many LLM-backed skill improvements per UTC day.
  final int maxImprovementsPerDay;
}

/// Usage statistics snapshot for one skill.
class SkillUsage {
  const SkillUsage({
    required this.count,
    required this.successRate,
    this.lastUsed,
  });

  final int count;
  final double successRate;
  final DateTime? lastUsed;
}

/// User feedback for one skill.
class SkillFeedback {
  SkillFeedback({
    required this.isPositive,
    this.comment = '',
    DateTime? at,
  }) : at = at ?? DateTime.now();

  final bool isPositive;
  final String comment;
  final DateTime at;

  Map<String, dynamic> toJson() => {
        'isPositive': isPositive,
        'comment': comment,
        'at': at.toIso8601String(),
      };

  factory SkillFeedback.fromJson(Map<String, dynamic> json) => SkillFeedback(
        isPositive: json['isPositive'] as bool? ?? false,
        comment: json['comment'] as String? ?? '',
        at: DateTime.tryParse(json['at'] as String? ?? '') ?? DateTime.now(),
      );
}

/// Tracks learning statistics for a session.
class SessionLearningStats {
  SessionLearningStats({
    this.sessionId = '',
    this.skillsCreated = 0,
    this.skillsImproved = 0,
    this.nudgesTriggered = 0,
    this.lastNudgeTime,
    this.importantInformation = const [],
  });

  final String sessionId;
  int skillsCreated;
  int skillsImproved;
  int nudgesTriggered;
  DateTime? lastNudgeTime;
  List<String> importantInformation;

  Map<String, dynamic> toJson() => {
        'sessionId': sessionId,
        'skillsCreated': skillsCreated,
        'skillsImproved': skillsImproved,
        'nudgesTriggered': nudgesTriggered,
        'lastNudgeTime': lastNudgeTime?.toIso8601String(),
        'importantInformation': importantInformation,
      };

  factory SessionLearningStats.fromJson(Map<String, dynamic> json) {
    return SessionLearningStats(
      sessionId: json['sessionId'] as String? ?? '',
      skillsCreated: json['skillsCreated'] as int? ?? 0,
      skillsImproved: json['skillsImproved'] as int? ?? 0,
      nudgesTriggered: json['nudgesTriggered'] as int? ?? 0,
      lastNudgeTime: json['lastNudgeTime'] != null
          ? DateTime.tryParse(json['lastNudgeTime'] as String? ?? '')
          : null,
      importantInformation: (json['importantInformation'] as List<dynamic>?)
          ?.map((e) => e.toString())
          .toList() ??
          [],
    );
  }
}

/// Result of a skill synthesis operation.
class SkillSynthesisResult {
  const SkillSynthesisResult({
    required this.skill,
    required this.score,
    required this.success,
    this.error,
  });

  final Skill? skill;
  final double score;
  final bool success;
  final String? error;
}

/// Result of a skill improvement operation.
class SkillImprovementResult {
  const SkillImprovementResult({
    required this.originalSkill,
    required this.improvedSkill,
    required this.improvementScore,
    required this.success,
    this.error,
  });

  final Skill originalSkill;
  final Skill improvedSkill;
  final double improvementScore;
  final bool success;
  final String? error;
}

/// Engine for autonomous self-learning capabilities.
///
/// This implements the core self-improving loop similar to Hermes Agent:
/// 1. Autonomous skill creation from successful multi-step workflows
/// 2. Continuous skill improvement based on usage and feedback
/// 3. Periodic nudges to persist important knowledge
/// 4. Cross-session memory and skill evolution
class SelfLearningEngine {
  SelfLearningEngine({
    required this.llmProvider,
    required this.skillRegistry,
    required this.memoryStore,
    required this.sessionStore,
    SelfLearningConfig? config,
    this.skillsDir,
  }) : config = config ?? const SelfLearningConfig();

  final LlmProvider llmProvider;
  final SkillRegistry skillRegistry;
  final MemoryStore memoryStore;
  final SessionStore sessionStore;
  final SelfLearningConfig config;
  final String? skillsDir;

  final Map<String, SessionLearningStats> _sessionStats = {};
  final Map<String, List<SkillFeedback>> _feedbackLog = {};
  final Map<String, DateTime> _skillImprovedAt = {};
  DateTime? _lastImprovementRun;
  DateTime? _improvementDay;
  int _improvementsToday = 0;
  bool _isRunning = false;
  Timer? _improvementTimer;
  Future<void>? _improvementRun;
  bool _improving = false;

  String get _effectiveSkillsDir => skillsDir ?? config.skillsDirectory;

  /// Starts the self-learning engine.
  Future<void> start() async {
    if (_isRunning) return;
    _isRunning = true;
    
    // Start periodic improvement checks. A cancellable Timer keeps the
    // isolate exit-capable once stop() cancels it; a pending Future.delayed
    // loop would keep CLI processes alive forever.
    _improvementTimer?.cancel();
    _improvementTimer = Timer.periodic(config.improvementInterval, (_) {
      if (!_isRunning || _improving) return;
      _improving = true;
      _improvementRun = _improveAllSkills().whenComplete(() => _improving = false);
    });
    
    // Load existing stats if available
    await _loadStats();
  }

  /// Stops the self-learning engine.
  Future<void> stop() async {
    _isRunning = false;
    _improvementTimer?.cancel();
    _improvementTimer = null;
    await _improvementRun;
    await _saveStats();
  }

  File get _statsFile =>
      File(p.join(_effectiveSkillsDir, 'learning_stats.json'));

  Future<void> _loadStats() async {
    try {
      final file = _statsFile;
      if (!await file.exists()) return;
      final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      final sessions = json['session_stats'] as Map<String, dynamic>? ?? {};
      _sessionStats.clear();
      for (final entry in sessions.entries) {
        _sessionStats[entry.key] = SessionLearningStats.fromJson(
          Map<String, dynamic>.from(entry.value as Map),
        );
      }
      final feedback = json['feedback_log'] as Map<String, dynamic>? ?? {};
      _feedbackLog.clear();
      for (final entry in feedback.entries) {
        final list = entry.value as List? ?? const [];
        _feedbackLog[entry.key] = [
          for (final item in list)
            SkillFeedback.fromJson(Map<String, dynamic>.from(item as Map)),
        ];
      }
      final improvedAt = json['skill_improved_at'] as Map<String, dynamic>? ?? {};
      _skillImprovedAt.clear();
      for (final entry in improvedAt.entries) {
        final at = DateTime.tryParse(entry.value as String? ?? '');
        if (at != null) _skillImprovedAt[entry.key] = at;
      }
      final day = DateTime.tryParse(json['improvement_day'] as String? ?? '');
      if (day != null) {
        _improvementDay = DateTime.utc(day.year, day.month, day.day);
        _improvementsToday = json['improvements_today'] as int? ?? 0;
      }
      final lastRun = DateTime.tryParse(json['last_improvement_run'] as String? ?? '');
      if (lastRun != null) _lastImprovementRun = lastRun;
    } catch (_) {
      // Corrupt stats must never prevent the engine from starting.
    }
  }

  Future<void> _saveStats() async {
    try {
      final dir = Directory(_effectiveSkillsDir);
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      final tmp = File('${_statsFile.path}.tmp');
      await tmp.writeAsString(jsonEncode({
        'session_stats': {
          for (final entry in _sessionStats.entries) entry.key: entry.value.toJson(),
        },
        'feedback_log': {
          for (final entry in _feedbackLog.entries)
            entry.key: [for (final f in entry.value) f.toJson()],
        },
        'skill_improved_at': {
          for (final entry in _skillImprovedAt.entries)
            entry.key: entry.value.toIso8601String(),
        },
        'improvement_day': _improvementDay?.toIso8601String(),
        'improvements_today': _improvementsToday,
        'last_improvement_run': _lastImprovementRun?.toIso8601String(),
      }));
      await tmp.rename(_statsFile.path);
    } catch (_) {
      // Stats persistence is best-effort.
    }
  }

  /// Processes a conversation turn and potentially creates a new skill.
  ///
  /// This is called after each successful turn to check if the workflow
  /// is worth capturing as a reusable skill.
  Future<SkillSynthesisResult?> processTurn({
    required Session session,
    required ConversationTurn turn,
    required List<ToolCall> toolCalls,
    required int tokensUsed,
  }) async {
    if (!config.autoCreateEnabled) return null;
    
    // Check if turn meets synthesis criteria
    if (toolCalls.length < config.minToolCallsForSynthesis) {
      return null;
    }

    if (!_shouldSynthesize(session.id)) {
      return null;
    }

    // Calculate synthesis score
    final score = _calculateSynthesisScore(
      success: turn.isSuccessful,
      toolCalls: toolCalls.length,
      tokensUsed: tokensUsed,
    );

    if (score < config.synthesisThreshold) {
      return null;
    }

    // Create skill from turn
    final result = await _createSkillFromTurn(
      session: session,
      turn: turn,
      toolCalls: toolCalls,
      score: score,
    );

    if (result.success && result.skill != null) {
      _updateSessionStats(session.id, (stats) {
        stats.skillsCreated++;
      });
    }

    return result;
  }

  /// Calculates the synthesis score for a turn.
  double _calculateSynthesisScore({
    required bool success,
    required int toolCalls,
    required int tokensUsed,
  }) {
    // Success term (0 or 1)
    final successTerm = success ? 1.0 : 0.0;

    // Tool complexity term (normalized to [0, 1])
    final toolTerm = min(toolCalls / 10, 1.0); // Saturation at 10 tool calls

    // Efficiency term (fewer tokens = better)
    final referenceTokens = 20000;
    final tokenTerm = max(0, 1.0 - (tokensUsed / referenceTokens));

    // Weighted sum (same weights as Hermes: w1=0.5, w2=0.3, w3=0.2)
    return 0.5 * successTerm + 0.3 * toolTerm + 0.2 * tokenTerm;
  }

  /// Checks if we should synthesize a skill for this session.
  bool _shouldSynthesize(String sessionId) {
    final stats = _getOrCreateSessionStats(sessionId);
    return stats.skillsCreated < config.maxSkillsPerSession;
  }

  /// Creates a skill from a conversation turn.
  Future<SkillSynthesisResult> _createSkillFromTurn({
    required Session session,
    required ConversationTurn turn,
    required List<ToolCall> toolCalls,
    required double score,
  }) async {
    try {
      // Extract key information from the turn
      final goal = turn.userMessage ?? 'Unknown task';
      final outcome = turn.assistantMessage ?? '';
      final toolsUsed = toolCalls.map((tc) => tc.name).toList();

      // Generate skill using LLM
      final skill = await _generateSkill(
        goal: goal,
        outcome: outcome,
        tools: toolsUsed,
      );

      if (skill == null) {
        return SkillSynthesisResult(
          skill: null,
          score: score,
          success: false,
          error: 'Failed to generate skill',
        );
      }

      // Dedup: re-registering an existing slug would replace the registry
      // entry and reset its promotion status and usage metrics. The
      // improvement flow owns updates to existing skills.
      if (skillRegistry.get(skill.slug) != null) {
        return SkillSynthesisResult(
          skill: null,
          score: score,
          success: false,
          error: 'skill already exists: ${skill.slug}',
        );
      }

      // Save skill
      final savedSkill = await _saveSkill(skill);

      return SkillSynthesisResult(
        skill: savedSkill,
        score: score,
        success: true,
      );
    } catch (e) {
      return SkillSynthesisResult(
        skill: null,
        score: score,
        success: false,
        error: e.toString(),
      );
    }
  }

  /// Generates a skill from turn data using LLM.
  Future<Skill?> _generateSkill({
    required String goal,
    required String outcome,
    required List<String> tools,
  }) async {
    final prompt = _buildSynthesisPrompt(goal, outcome, tools);
    
    final request = ChatRequest(
      messages: [
        const ChatMessage(
          role: 'system',
          content: '''
You are a skill synthesis engine. Your task is to create a reusable SKILL.md 
from a successful multi-step workflow. Follow these guidelines:

1. Analyze the goal, outcome, and tools used
2. Create a clear, actionable procedure
3. Include pitfalls and verification steps
4. Use markdown format with proper sections
5. Keep the description under 60 characters
6. Use the standard SKILL.md format

Output ONLY the SKILL.md content, nothing else.
''',
        ),
        ChatMessage(role: 'user', content: prompt),
      ],
      stream: false,
      temperature: 0.2,
    );

    final response = await llmProvider.chat(request).first;
    
    if (response is! LlmTextDelta) {
      return null;
    }

    // Parse the response into a Skill object
    return _parseSkillFromResponse(response.delta);
  }

  String _buildSynthesisPrompt(String goal, String outcome, List<String> tools) {
    return '''
Goal: $goal

Outcome: $outcome

Tools used: ${tools.join(', ')}

Create a SKILL.md that captures this workflow for future reuse.
''';
  }

  Skill? _parseSkillFromResponse(String response) {
    // Parse the response into a Skill object
    // This is a simplified implementation
    // In production, you'd want more robust parsing
    
    try {
      // Try to extract skill metadata and content
      final name = _extractSkillName(response);
      final description = _extractSkillDescription(response);
      final triggers = _extractTriggers(response);
      final content = response;
      
      if (name.isEmpty) {
        return null;
      }

      return Skill(
        slug: _slugify(name),
        name: name,
        description: description,
        body: content,
        triggers: triggers,
        status: SkillStatus.draft,
        version: 1,
      );
    } catch (e) {
      return null;
    }
  }

  /// Extracts `triggers: [a, b]` (or comma list) from YAML frontmatter.
  /// Without triggers a skill can never be matched by [SkillRegistry.match],
  /// so the learning loop would never close.
  List<String> _extractTriggers(String response) {
    for (final line in response.split('\n')) {
      final l = line.trim();
      if (!l.startsWith('triggers:')) continue;
      final raw = l.substring('triggers:'.length).trim();
      final inner = raw.startsWith('[') && raw.endsWith(']')
          ? raw.substring(1, raw.length - 1)
          : raw;
      return inner
          .split(',')
          .map((s) => s.trim().replaceAll('"', '').replaceAll("'", ''))
          .where((s) => s.isNotEmpty)
          .toList();
    }
    return const [];
  }

  String _extractSkillName(String response) {
    // Look for name in YAML frontmatter or first heading
    final lines = response.split('\n');
    
    for (final line in lines) {
      if (line.startsWith('name:')) {
        return line.substring('name:'.length).trim();
      }
      if (line.startsWith('# ')) {
        return line.substring(2).trim();
      }
    }
    
    // Fallback: use first non-empty line
    for (final line in lines) {
      if (line.trim().isNotEmpty) {
        return line.trim();
      }
    }
    
    return '';
  }

  String _extractSkillDescription(String response) {
    // Look for description in YAML frontmatter
    final lines = response.split('\n');
    
    for (final line in lines) {
      if (line.startsWith('description:')) {
        return line.substring('description:'.length).trim();
      }
    }
    
    return '';
  }

  String _slugify(String name) {
    return name
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
  }

  /// Saves a skill to the skills directory.
  Future<Skill> _saveSkill(Skill skill) async {
    final dir = Directory(_effectiveSkillsDir);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }

    // Create skill directory
    final skillDir = Directory(p.join(_effectiveSkillsDir, skill.slug));
    if (!await skillDir.exists()) {
      await skillDir.create(recursive: true);
    }

    // Save SKILL.md
    final skillFile = File(p.join(skillDir.path, 'SKILL.md'));
    await skillFile.writeAsString(_skillToMarkdown(skill));

    // Register with skill registry
    skillRegistry.register(skill);

    return skill;
  }

  /// Serializes a skill to the SKILL.md format understood by SkillParser.
  String _skillToMarkdown(Skill skill) {
    final buffer = StringBuffer('---\n')
      ..writeln('name: ${skill.name}')
      ..writeln('description: ${skill.description}')
      ..writeln('triggers: [${skill.triggers.join(', ')}]')
      ..writeln('tools: [${skill.tools.join(', ')}]')
      ..writeln('version: ${skill.version}')
      ..writeln('status: ${skill.status.name}')
      ..writeln('---')
      ..writeln()
      ..write(skill.body.trim());
    return buffer.toString();
  }

  /// Triggers a memory nudge for the session.
  Future<bool> triggerNudge(Session session, String message) async {
    if (!config.nudgeEnabled) return false;

    final stats = _getOrCreateSessionStats(session.id);
    
    // Check if we should trigger a nudge
    if (stats.lastNudgeTime != null) {
      final now = DateTime.now();
      if (now.difference(stats.lastNudgeTime!) < config.nudgeInterval) {
        return false;
      }
    }

    // Inject the nudge into the conversation
    // This would typically be done through the agent loop
    
    _updateSessionStats(session.id, (stats) {
      stats.lastNudgeTime = DateTime.now();
      stats.nudgesTriggered++;
    });

    return true;
  }

  /// Detects important information that should be persisted.
  List<String> detectImportantInformation(ConversationTurn turn) {
    // This is a placeholder implementation
    // In production, you'd use more sophisticated analysis
    
    final List<String> important = [];

    // Look for patterns that indicate important information
    // e.g., configurations, decisions, learnings

    return important;
  }

  /// Improves all skills based on usage and feedback, bounded by the
  /// configured per-cycle and per-day cost caps.
  Future<void> _improveAllSkills() async {
    if (!config.autoImproveEnabled) return;

    final now = DateTime.now().toUtc();
    final today = DateTime.utc(now.year, now.month, now.day);
    if (_improvementDay != today) {
      _improvementDay = today;
      _improvementsToday = 0;
    }

    var cycleImprovements = 0;
    for (final skill in skillRegistry.all) {
      if (cycleImprovements >= config.maxImprovementsPerCycle) break;
      if (_improvementsToday >= config.maxImprovementsPerDay) break;
      final usage = SkillUsage(
        count: skill.uses,
        successRate: skill.successRate,
      );
      final feedback = _feedbackLog[skill.slug] ?? const <SkillFeedback>[];

      if (_shouldImproveSkill(skill, usage, feedback)) {
        final result = await _improveSkill(skill, usage, feedback);
        if (result?.success ?? false) {
          cycleImprovements++;
          _improvementsToday++;
          _skillImprovedAt[skill.slug] = DateTime.now();
          _updateSessionStats('global', (stats) {
            stats.skillsImproved++;
          });
        }
      }
    }
    
    _lastImprovementRun = DateTime.now();
  }

  bool _shouldImproveSkill(
    Skill skill,
    SkillUsage usage,
    List<SkillFeedback> feedback,
  ) {
    // Improve if:
    // - Used more than N times
    // - Has negative feedback
    // - Hasn't been improved recently
    
    if (usage.count > 10) {
      return true;
    }
    
    if (feedback.any((f) => !f.isPositive)) {
      return true;
    }
    
    final improvedAt = _skillImprovedAt[skill.slug];
    if (improvedAt != null) {
      final daysSinceUpdate = DateTime.now().difference(improvedAt).inDays;
      if (daysSinceUpdate > 7) {
        return true;
      }
    }
    
    return false;
  }

  /// Improves a single skill based on usage and feedback.
  Future<SkillImprovementResult?> _improveSkill(
    Skill skill,
    SkillUsage usage,
    List<SkillFeedback> feedback,
  ) async {
    try {
      // Generate improved version using LLM
      final improvedContent = await _generateImprovedSkill(
        skill: skill,
        usage: usage,
        feedback: feedback,
      );

      if (improvedContent == null) {
        return null;
      }

      // Promotion gate (static stage): an LLM rewrite must pass the same
      // static scan as a synthesized skill before it may replace the file.
      final scan = SkillScanner.scanContent(improvedContent);
      if (!scan.ok) {
        return SkillImprovementResult(
          originalSkill: skill,
          improvedSkill: skill,
          improvementScore: 0,
          success: false,
          error: 'static scan rejected: ${scan.findings.join(', ')}',
        );
      }

      // Keep the current version recoverable before the candidate lands.
      await _backupCurrentVersion(skill);

      // A rewritten skill demotes to trial: approval must be re-earned, the
      // previous version stays restorable from the versions/ backup.
      final improvedSkill = Skill(
        slug: skill.slug,
        name: skill.name,
        description: skill.description,
        body: improvedContent,
        status: SkillStatus.trial,
        version: skill.version + 1,
      );

      // Save improved skill
      await _saveSkill(improvedSkill);

      return SkillImprovementResult(
        originalSkill: skill,
        improvedSkill: improvedSkill,
        improvementScore: _measuredImprovementScore(skill, usage, feedback),
        success: true,
      );
    } catch (e) {
      return SkillImprovementResult(
        originalSkill: skill,
        improvedSkill: skill,
        improvementScore: 0,
        success: false,
        error: e.toString(),
      );
    }
  }

  /// Score from measured signals only: current success rate and the
  /// positive-feedback ratio. Never a placeholder, never above what the
  /// skill has actually demonstrated.
  double _measuredImprovementScore(
    Skill skill,
    SkillUsage usage,
    List<SkillFeedback> feedback,
  ) {
    final positive = feedback.where((f) => f.isPositive).length;
    final feedbackScore =
        feedback.isEmpty ? 0.0 : positive / feedback.length;
    final combined = 0.5 * usage.successRate + 0.5 * feedbackScore;
    return combined.clamp(0.0, 1.0);
  }

  /// Copies the currently deployed SKILL.md into versions/v`<n>`.md so a bad
  /// auto-improvement can be rolled back manually.
  Future<void> _backupCurrentVersion(Skill skill) async {
    try {
      final current = File(p.join(
        _effectiveSkillsDir,
        skill.slug,
        'SKILL.md',
      ));
      if (!await current.exists()) return;
      final versionsDir = Directory(p.join(
        _effectiveSkillsDir,
        skill.slug,
        'versions',
      ));
      if (!await versionsDir.exists()) {
        await versionsDir.create(recursive: true);
      }
      await File(p.join(versionsDir.path, 'v${skill.version}.md'))
          .writeAsString(await current.readAsString());
    } catch (_) {
      // A failed backup must not block the improvement itself.
    }
  }

  Future<String?> _generateImprovedSkill({
    required Skill skill,
    required SkillUsage usage,
    required List<SkillFeedback> feedback,
  }) async {
    final prompt = _buildImprovementPrompt(skill, usage, feedback);
    
    final request = ChatRequest(
      messages: [
        const ChatMessage(
          role: 'system',
          content: '''
You are a skill improvement engine. Your task is to improve an existing SKILL.md 
based on usage data and feedback. Follow these guidelines:

1. Analyze the current skill content
2. Incorporate lessons learned from usage
3. Address any negative feedback
4. Improve clarity and completeness
5. Maintain the standard SKILL.md format

Output ONLY the improved SKILL.md content, nothing else.
''',
        ),
        ChatMessage(role: 'user', content: prompt),
      ],
      stream: false,
      temperature: 0.2,
    );

    final response = await llmProvider.chat(request).first;
    
    if (response is! LlmTextDelta) {
      return null;
    }

    return response.delta;
  }

  String _buildImprovementPrompt(
    Skill skill,
    SkillUsage usage,
    List<SkillFeedback> feedback,
  ) {
    return '''
Current SKILL.md:
${skill.body}

Usage data:
- Used ${usage.count} times
- Success rate: ${(usage.successRate * 100).toStringAsFixed(1)}%
- Last used: ${usage.lastUsed?.toIso8601String() ?? 'unknown'}

Feedback:
${feedback.map((f) => '- ${f.isPositive ? '✓' : '✗'} ${f.comment}').join('\n')}

Improve this skill based on the usage data and feedback.
''';
  }

  /// Records user feedback for a skill (used by the improvement loop).
  void recordSkillFeedback(
    String slug, {
    required bool positive,
    String comment = '',
  }) {
    _feedbackLog.putIfAbsent(slug, () => []).add(
          SkillFeedback(isPositive: positive, comment: comment),
        );
  }

  /// Gets or creates learning stats for a session.
  SessionLearningStats _getOrCreateSessionStats(String sessionId) {
    return _sessionStats.putIfAbsent(
      sessionId,
      () => SessionLearningStats(sessionId: sessionId),
    );
  }

  /// Updates learning stats for a session.
  void _updateSessionStats(
    String sessionId,
    void Function(SessionLearningStats) updater,
  ) {
    final stats = _getOrCreateSessionStats(sessionId);
    updater(stats);
  }

  /// Gets learning stats for a session.
  SessionLearningStats? getSessionStats(String sessionId) {
    return _sessionStats[sessionId];
  }

  /// Gets overall learning statistics.
  Map<String, dynamic> getStatistics() {
    final totalSkillsCreated = _sessionStats.values
        .fold<int>(0, (sum, stats) => sum + stats.skillsCreated);
    final totalSkillsImproved = _sessionStats.values
        .fold<int>(0, (sum, stats) => sum + stats.skillsImproved);
    final totalNudges = _sessionStats.values
        .fold<int>(0, (sum, stats) => sum + stats.nudgesTriggered);

    return {
      'totalSkillsCreated': totalSkillsCreated,
      'totalSkillsImproved': totalSkillsImproved,
      'totalNudgesTriggered': totalNudges,
      'activeSessions': _sessionStats.length,
      'lastImprovementRun': _lastImprovementRun?.toIso8601String(),
    };
  }
}

/// Mixin to integrate self-learning with the agent loop.
mixin SelfLearningAgentLoop on AgentLoop {
  SelfLearningEngine? _learningEngine;

  /// Enables self-learning for this agent loop.
  void enableSelfLearning(SelfLearningEngine engine) {
    _learningEngine = engine;
  }

  /// Processes a turn for self-learning.
  Future<void> processTurnForLearning({
    required Session session,
    required ConversationTurn turn,
    required List<ToolCall> toolCalls,
    required int tokensUsed,
  }) async {
    if (_learningEngine != null) {
      await _learningEngine!.processTurn(
        session: session,
        turn: turn,
        toolCalls: toolCalls,
        tokensUsed: tokensUsed,
      );
    }
  }
}

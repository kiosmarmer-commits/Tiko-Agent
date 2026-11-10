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
  DateTime? _lastImprovementRun;
  bool _isRunning = false;

  String get _effectiveSkillsDir => skillsDir ?? config.skillsDirectory;

  /// Starts the self-learning engine.
  Future<void> start() async {
    if (_isRunning) return;
    _isRunning = true;
    
    // Start periodic improvement checks
    _startPeriodicImprovement();
    
    // Load existing stats if available
    await _loadStats();
  }

  /// Stops the self-learning engine.
  Future<void> stop() async {
    _isRunning = false;
    await _saveStats();
  }

  Future<void> _startPeriodicImprovement() async {
    while (_isRunning) {
      await Future.delayed(config.improvementInterval);
      if (_isRunning) {
        await _improveAllSkills();
      }
    }
  }

  Future<void> _loadStats() async {
    // Load from persistent storage if available
  }

  Future<void> _saveStats() async {
    // Save to persistent storage
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
      final content = response;
      
      if (name.isEmpty) {
        return null;
      }

      return Skill(
        slug: _slugify(name),
        name: name,
        description: description,
        body: content,
        status: SkillStatus.draft,
        version: 1,
      );
    } catch (e) {
      return null;
    }
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
    await skillFile.writeAsString(skill.content);

    // Register with skill registry
    await skillRegistry.registerSkill(skill);

    return skill;
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
    final text = turn.assistantMessage ?? '';
    
    // Look for patterns that indicate important information
    // e.g., configurations, decisions, learnings
    
    return important;
  }

  /// Improves all skills based on usage and feedback.
  Future<void> _improveAllSkills() async {
    if (!config.autoImproveEnabled) return;
    
    final skills = await skillRegistry.listSkills();
    
    for (final skill in skills) {
      final usage = await skillRegistry.getSkillUsage(skill.slug);
      final feedback = await skillRegistry.getSkillFeedback(skill.slug);
      
      if (_shouldImproveSkill(skill, usage, feedback)) {
        await _improveSkill(skill, usage, feedback);
        _updateSessionStats('global', (stats) {
          stats.skillsImproved++;
        });
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
    
    if (skill.metadata.updatedAt != null) {
      final daysSinceUpdate = DateTime.now()
          .difference(skill.metadata.updatedAt!)
          .inDays;
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

      // Create improved skill
      final improvedSkill = Skill(
        slug: skill.slug,
        name: skill.name,
        description: skill.description,
        body: improvedContent,
        status: skill.status,
        version: skill.version + 1,
      );

      // Save improved skill
      await _saveSkill(improvedSkill);

      return SkillImprovementResult(
        originalSkill: skill,
        improvedSkill: improvedSkill,
        improvementScore: 1.0, // Placeholder
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
${skill.content}

Usage data:
- Used ${usage.count} times
- Success rate: ${usage.successRate * 100}%
- Last used: ${usage.lastUsed}

Feedback:
${feedback.map((f) => '- ${f.isPositive ? '✓' : '✗'} ${f.comment}').join('\n')}

Improve this skill based on the usage data and feedback.
''';
  }

  String _incrementVersion(String version) {
    // Simple version increment logic
    final parts = version.split('.');
    if (parts.length >= 3) {
      final patch = int.tryParse(parts[2]) ?? 0;
      parts[2] = (patch + 1).toString();
    } else {
      parts.add('1');
    }
    return parts.join('.');
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

/// Extension to integrate self-learning with the agent loop.
extension SelfLearningAgentLoop on AgentLoop {
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

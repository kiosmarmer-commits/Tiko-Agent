import 'dart:convert';
import 'package:agent_core/agent_core.dart';

typedef SubagentRunner = Future<SubagentResult> Function({
  required String goal,
  required String context,
  required Session parent,
  required int depth,
  required SubagentBudget budget,
  required Set<String> allowedTools,
});

/// Budget constraints for a subagent (P1-09).
class SubagentBudget {
  const SubagentBudget({
    this.maxTokens = 4000,
    this.maxTimeSeconds = 120,
    this.maxToolCalls = 10,
    this.maxCost = 0.5,
  });

  final int maxTokens;
  final int maxTimeSeconds;
  final int maxToolCalls;
  final double maxCost;

  Map<String, dynamic> toJson() => {
    'max_tokens': maxTokens,
    'max_time_seconds': maxTimeSeconds,
    'max_tool_calls': maxToolCalls,
    'max_cost': maxCost,
  };
}

/// Structured result from a subagent execution (P1-09).
class SubagentResult {
  const SubagentResult({
    required this.success,
    required this.output,
    this.error,
    this.tokenCount = 0,
    this.timeSeconds = 0.0,
    this.toolCallCount = 0,
    this.cost = 0.0,
    this.subagentId,
    this.parentId,
    this.startedAt,
    this.completedAt,
  });

  final bool success;
  final String output;
  final String? error;
  final int tokenCount;
  final double timeSeconds;
  final int toolCallCount;
  final double cost;
  final String? subagentId;
  final String? parentId;
  final DateTime? startedAt;
  final DateTime? completedAt;

  Map<String, dynamic> toJson() => {
    'success': success,
    'output': output,
    'error': error,
    'token_count': tokenCount,
    'time_seconds': timeSeconds,
    'tool_call_count': toolCallCount,
    'cost': cost,
    'subagent_id': subagentId,
    'parent_id': parentId,
    'started_at': startedAt?.toIso8601String(),
    'completed_at': completedAt?.toIso8601String(),
  };

  String toSummary() =>
      'Subagent ${success ? 'sukses' : 'gagal'}: ${output.length > 100 ? output.substring(0, 100) + '...' : output}';
}

/// spawn_subagent — parallel research with separate token budget (ALG-04, P1-09).
class SpawnSubagentTool implements Tool {
  SpawnSubagentTool({
    this.maxDepth = 2,
    this.runner,
    this.maxSubagents = 4,
    this.defaultBudget = const SubagentBudget(),
    this.defaultAllowedTools = const {},
  });

  final int maxDepth;
  final SubagentRunner? runner;
  final int maxSubagents;
  final SubagentBudget defaultBudget;
  final Set<String> defaultAllowedTools;

  static final _depth = <String, int>{};
  static final _activeSubagents = <String, DateTime>{};

  static int depthOf(Session s) => _depth[s.id] ?? 0;
  static void setDepth(Session s, int d) => _depth[s.id] = d;

  /// Track active subagents to enforce maxSubagents limit (P1-09).
  static bool registerSubagent(String id) {
    if (_activeSubagents.length >= 4) return false;
    _activeSubagents[id] = DateTime.now();
    return true;
  }

  static void unregisterSubagent(String id) {
    _activeSubagents.remove(id);
  }

  static int activeSubagentCount() => _activeSubagents.length;

  @override
  ToolSpec get spec => const ToolSpec(
    name: 'spawn_subagent',
    description:
        'Bagi tugas independen ke subagent (kedalaman maks 2, maks 4 subagent aktif). Argumen: goal, context opsional, budget opsional, allowed_tools opsional.',
    inputSchema: {
      'type': 'object',
      'properties': {
        'goal': {'type': 'string'},
        'context': {'type': 'string'},
        'budget': {
          'type': 'object',
          'properties': {
            'max_tokens': {'type': 'integer', 'minimum': 100, 'maximum': 100000},
            'max_time_seconds': {'type': 'integer', 'minimum': 1, 'maximum': 1800},
            'max_tool_calls': {'type': 'integer', 'minimum': 1, 'maximum': 100},
            'max_cost': {'type': 'number', 'minimum': 0.0, 'maximum': 10.0},
          },
        },
        'allowed_tools': {
          'type': 'array',
          'items': {'type': 'string'},
        },
      },
      'required': ['goal'],
    },
    risk: 'medium',
    timeoutSec: 120,
  );

  @override
  Future<ToolResult> run(Map<String, dynamic> args, ToolContext ctx) async {
    final goal = (args['goal'] as String?)?.trim() ?? '';
    if (goal.isEmpty) {
      return const ToolResult(callId: '', content: 'goal wajib', isError: true);
    }

    final depth = depthOf(ctx.session);
    if (depth >= maxDepth) {
      return ToolResult(
        callId: '',
        content: 'Batas kedalaman subagent ($maxDepth) tercapai',
        isError: true,
      );
    }

    // Check max concurrent subagents limit (P1-09)
    if (activeSubagentCount() >= maxSubagents) {
      return ToolResult(
        callId: '',
        content: 'Batas jumlah subagent aktif ($maxSubagents) tercapai',
        isError: true,
      );
    }

    final context = args['context'] as String? ?? '';
    final budget = _parseBudget(args['budget'] as Map<String, dynamic>?);
    final allowedTools = _parseAllowedTools(args['allowed_tools']);

    if (runner != null) {
      final subagentId = '${ctx.session.id}/sub/${depth + 1}/${DateTime.now().microsecondsSinceEpoch}';
      
      try {
        // Register subagent before execution
        if (!registerSubagent(subagentId)) {
          return ToolResult(
            callId: '',
            content: 'Tidak dapat mendaftarkan subagent',
            isError: true,
          );
        }

        final startTime = DateTime.now();
        final result = await runner!(
          goal: goal,
          context: context,
          parent: ctx.session,
          depth: depth + 1,
          budget: budget,
          allowedTools: allowedTools,
        );
        final endTime = DateTime.now();

        // Calculate duration
        final duration = endTime.difference(startTime);
        final timeSeconds = duration.inMilliseconds / 1000.0;

        // Check budget limits
        if (result.tokenCount > budget.maxTokens) {
          unregisterSubagent(subagentId);
          return ToolResult(
            callId: '',
            content: 'Subagent melebihi batas token: ${result.tokenCount} > ${budget.maxTokens}',
            isError: true,
          );
        }
        final reportedTime = timeSeconds > result.timeSeconds
            ? timeSeconds
            : result.timeSeconds;
        if (reportedTime > budget.maxTimeSeconds) {
          unregisterSubagent(subagentId);
          return ToolResult(
            callId: '',
            content: 'Subagent melebihi batas waktu: ${reportedTime.toStringAsFixed(2)}s > ${budget.maxTimeSeconds}s',
            isError: true,
          );
        }
        if (result.toolCallCount > budget.maxToolCalls) {
          unregisterSubagent(subagentId);
          return ToolResult(
            callId: '',
            content: 'Subagent melebihi batas tool calls: ${result.toolCallCount} > ${budget.maxToolCalls}',
            isError: true,
          );
        }
        if (result.cost > budget.maxCost) {
          unregisterSubagent(subagentId);
          return ToolResult(
            callId: '',
            content: 'Subagent melebihi batas biaya: ${result.cost} > ${budget.maxCost}',
            isError: true,
          );
        }

        // Unregister subagent after successful completion
        unregisterSubagent(subagentId);

        final payload = result.toJson();
        final content =
            '${result.toSummary()}\n\n<subagent_result>${jsonEncode(payload)}</subagent_result>';
        return ToolResult(
          callId: '',
          content: content,
          isError: !result.success,
        );
      } catch (e) {
        unregisterSubagent(subagentId);
        return ToolResult(
          callId: '',
          content: 'subagent error: $e',
          isError: true,
        );
      }
    }

    return ToolResult(
      callId: '',
      content:
          'SUBAGENT_REQUEST depth=${depth + 1}\ngoal: $goal\ncontext: $context\n'
          '(Host belum memasang runner subagent.)',
    );
  }

  SubagentBudget _parseBudget(Map<String, dynamic>? input) {
    if (input == null) return defaultBudget;
    return SubagentBudget(
      maxTokens: input['max_tokens'] as int? ?? defaultBudget.maxTokens,
      maxTimeSeconds: input['max_time_seconds'] as int? ?? defaultBudget.maxTimeSeconds,
      maxToolCalls: input['max_tool_calls'] as int? ?? defaultBudget.maxToolCalls,
      maxCost: input['max_cost'] as double? ?? defaultBudget.maxCost,
    );
  }

  Set<String> _parseAllowedTools(dynamic input) {
    if (input is List) {
      return input.map((e) => e.toString()).toSet();
    }
    return defaultAllowedTools;
  }
}

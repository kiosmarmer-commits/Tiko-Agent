import 'package:agent_core/agent_core.dart';

typedef SubagentRunner =
    Future<String> Function({
      required String goal,
      required String context,
      required Session parent,
      required int depth,
    });

/// spawn_subagent — parallel research with separate token budget (ALG-04).
class SpawnSubagentTool implements Tool {
  SpawnSubagentTool({this.maxDepth = 2, this.runner});

  final int maxDepth;
  final SubagentRunner? runner;

  static final _depth = <String, int>{};

  static int depthOf(Session s) => _depth[s.id] ?? 0;
  static void setDepth(Session s, int d) => _depth[s.id] = d;

  @override
  ToolSpec get spec => const ToolSpec(
    name: 'spawn_subagent',
    description:
        'Bagi tugas independen ke subagent (kedalaman maks 2). Argumen: goal, context opsional.',
    inputSchema: {
      'type': 'object',
      'properties': {
        'goal': {'type': 'string'},
        'context': {'type': 'string'},
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
    final context = args['context'] as String? ?? '';
    if (runner != null) {
      try {
        final out = await runner!(
          goal: goal,
          context: context,
          parent: ctx.session,
          depth: depth + 1,
        );
        return ToolResult(callId: '', content: out);
      } catch (e) {
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
}

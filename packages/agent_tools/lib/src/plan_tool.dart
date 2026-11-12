import 'package:agent_core/agent_core.dart';

/// plan_task — generate a numbered plan without executing (ALG-02 entry tool).
class PlanTaskTool implements Tool {
  PlanTaskTool(this.planner);
  final PlanExecute planner;

  @override
  ToolSpec get spec => const ToolSpec(
    name: 'plan_task',
    description:
        'Buat rencana langkah bernomor untuk tujuan kompleks, tanpa mengeksekusi.',
    inputSchema: {
      'type': 'object',
      'properties': {
        'goal': {'type': 'string'},
        'max_steps': {'type': 'integer'},
      },
      'required': ['goal'],
    },
    risk: 'low',
    timeoutSec: 60,
  );

  @override
  Future<ToolResult> run(Map<String, dynamic> args, ToolContext ctx) async {
    final goal = (args['goal'] as String?)?.trim() ?? '';
    if (goal.isEmpty) {
      return const ToolResult(callId: '', content: 'goal wajib', isError: true);
    }
    final maxSteps = (args['max_steps'] as num?)?.toInt() ?? 6;
    try {
      final steps = await planner.plan(goal, maxSteps: maxSteps);
      if (steps.isEmpty) {
        return const ToolResult(
          callId: '',
          content: '(rencana kosong)',
          isError: true,
        );
      }
      final body = steps
          .asMap()
          .entries
          .map((e) => '${e.key + 1}. ${e.value}')
          .join('\n');
      return ToolResult(callId: '', content: 'Rencana:\n$body');
    } catch (e) {
      return ToolResult(
        callId: '',
        content: 'plan_task error: $e',
        isError: true,
      );
    }
  }
}

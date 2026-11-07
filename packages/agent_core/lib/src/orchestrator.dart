import 'interfaces.dart';
import 'models.dart';
import 'plan_execute.dart';
import 'agent_loop.dart';

/// Orchestrates plan → sequential step execution (ALG-02 full path).
class PlanExecuteOrchestrator {
  PlanExecuteOrchestrator({
    required this.llm,
    required this.loopFactory,
    this.maxSteps = 6,
  });

  final LlmProvider llm;
  final Future<void> Function(InboundMessage m, Session session) Function()
  loopFactory;
  final int maxSteps;

  /// Returns final combined answer.
  Future<String> run({
    required String goal,
    required Session session,
    required ReplyFn reply,
  }) async {
    final planner = PlanExecute(llm);
    final steps = await planner.plan(goal, maxSteps: maxSteps);
    if (steps.isEmpty) {
      await reply(
        InboundMessage(
          channel: session.channel,
          userKey: session.userKey,
          sessionKey: session.id,
          text: goal,
        ),
        'Tidak dapat membuat rencana.',
      );
      return '';
    }

    final planText = steps
        .asMap()
        .entries
        .map((e) => '${e.key + 1}. ${e.value}')
        .join('\n');
    await reply(
      InboundMessage(
        channel: session.channel,
        userKey: session.userKey,
        sessionKey: session.id,
        text: goal,
      ),
      'Rencana:\n$planText\n\nMenjalankan langkah…',
    );

    final outcomes = <String>[];
    for (var i = 0; i < steps.length; i++) {
      final step = steps[i];
      final stepSession = Session(
        id: '${session.id}/plan/${i + 1}',
        channel: session.channel,
        userKey: session.userKey,
      );
      final handle = loopFactory();
      await handle(
        InboundMessage(
          channel: 'plan',
          userKey: session.userKey,
          sessionKey: stepSession.id,
          text:
              'Langkah ${i + 1}/${steps.length}: $step\n\nKonteks tujuan: $goal',
        ),
        stepSession,
      );
      // replies captured by host if loopFactory wires them — fallback message
      outcomes.add('Langkah ${i + 1}: $step → (selesai)');
    }

    final summary = StringBuffer()
      ..writeln('Selesai ${steps.length} langkah.')
      ..writeln(outcomes.join('\n'));
    await reply(
      InboundMessage(
        channel: session.channel,
        userKey: session.userKey,
        sessionKey: session.id,
        text: goal,
      ),
      summary.toString(),
    );
    return summary.toString();
  }
}

import 'package:agent_core/agent_core.dart';
import 'package:agent_tools/agent_tools.dart';

/// ContextBuilder yang selalu mengiklankan tool dari [registry] (CLI M1 tidak
/// memakai skill registry, jadi iklan tool berasal langsung dari registry).
class CliContextBuilder extends ContextBuilder {
  CliContextBuilder({required this.registry, required ContextBuilder inner})
    : super(systemPrompt: inner.systemPrompt, memory: inner.memory);

  final ToolRegistry registry;

  @override
  Future<AgentContext> build(
    Session session,
    InboundMessage m,
    RouteDecision route,
  ) async {
    final ctx = await super.build(session, m, route);
    return AgentContext(
      messages: ctx.messages,
      tools: registry.specs,
      session: ctx.session,
      systemPrompt: ctx.systemPrompt,
    );
  }
}

import 'package:agent_core/agent_core.dart';

/// Probe model tool-calling with a dummy tool (AGD-02 P-06).
class CapabilityProbe {
  static Future<Capabilities> probe(LlmProvider llm) async {
    final dummy = [
      const ToolSpec(
        name: '__probe',
        description: 'probe only',
        inputSchema: {'type': 'object', 'properties': {}},
        risk: 'low',
      ),
    ];
    try {
      var sawTool = false;
      var sawStream = false;
      await for (final e in llm.chat(
        ChatRequest(
          messages: const [
            ChatMessage(
              role: 'system',
              content: 'Call tool __probe once if you support tools.',
            ),
            ChatMessage(role: 'user', content: 'probe'),
          ],
          tools: dummy,
          stream: true,
          temperature: 0,
          maxTokens: 64,
        ),
      )) {
        if (e is LlmTextDelta) sawStream = true;
        if (e is LlmToolCall) sawTool = true;
      }
      final base = llm.capabilities;
      return Capabilities(
        toolCalling: sawTool || base.toolCalling,
        vision: base.vision,
        logprobs: base.logprobs,
        streaming: sawStream || base.streaming,
        jsonSchemaOutput: base.jsonSchemaOutput,
        maxContext: base.maxContext,
      );
    } catch (_) {
      return llm.capabilities;
    }
  }
}

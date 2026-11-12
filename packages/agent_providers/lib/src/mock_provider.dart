import 'dart:async';

import 'package:agent_core/agent_core.dart';

/// Deterministic mock LLM for unit tests and early development (TASK-01-03).
///
/// Supports three scenarios:
/// 1. Plain text reply (no tools).
/// 2. Single tool call then final answer.
/// 3. Multi-step tool calling (loop of 2).
class MockLlmProvider implements LlmProvider {
  MockLlmProvider({this.scenario = MockScenario.plain});

  MockScenario scenario;
  int _turn = 0;

  @override
  String get id => 'mock';

  @override
  Capabilities get capabilities =>
      const Capabilities(toolCalling: true, streaming: true, maxContext: 8192);

  @override
  Stream<LlmEvent> chat(ChatRequest req) async* {
    _turn++;
    final lastUser = req.messages.lastWhere(
      (m) => m.role == 'user' || m.role == 'tool',
      orElse: () => const ChatMessage(role: 'user', content: ''),
    );

    switch (scenario) {
      case MockScenario.plain:
        yield const LlmTextDelta('Halo! Saya mock agent. ');
        yield const LlmTextDelta('Siap membantu.');
        yield const LlmUsage(TokenUsage(prompt: 20, completion: 10, total: 30));
        yield const LlmDone();

      case MockScenario.singleTool:
        if (_turn == 1 || lastUser.role == 'user') {
          final call = const ToolCall(
            id: 'call_mock_1',
            name: 'datetime',
            args: {},
          );
          yield LlmToolCall(call);
          yield const LlmUsage(
            TokenUsage(prompt: 40, completion: 15, total: 55),
          );
          yield const LlmDone(finishReason: 'tool_calls');
        } else {
          yield const LlmTextDelta(
            'Waktu saat ini (mock): 2026-11-04T10:00:00Z',
          );
          yield const LlmUsage(
            TokenUsage(prompt: 60, completion: 20, total: 80),
          );
          yield const LlmDone();
        }

      case MockScenario.multiTool:
        final toolCount = req.messages.where((m) => m.role == 'tool').length;
        if (toolCount == 0) {
          // Extract expression from last user message (PRD: deterministic args)
          final userText = lastUser.content;
          final m = RegExp(r'([0-9().+\-*/%^\s]+)').firstMatch(userText);
          var expr = '2+3';
          if (m != null) {
            final cand = m.group(1)!.trim();
            if (RegExp(r'\d').hasMatch(cand)) expr = cand;
          }
          // prefer explicit "hitung X" / "calc X"
          final m2 = RegExp(r'(?:hitung|calc)\s+(.+)\$', caseSensitive: false).firstMatch(userText.trim());
          if (m2 != null) expr = m2.group(1)!.trim();
          yield LlmToolCall(
            ToolCall(
              id: 'call_calc_1',
              name: 'calc',
              args: {'expression': expr},
            ),
          );
          yield const LlmDone(finishReason: 'tool_calls');
        } else if (toolCount == 1) {
          yield const LlmToolCall(
            ToolCall(id: 'call_dt_1', name: 'datetime', args: {}),
          );
          yield const LlmDone(finishReason: 'tool_calls');
        } else {
          final toolMsg = req.messages.where((m) => m.role == 'tool').map((m) => m.content).join('; ');
          yield LlmTextDelta('Hasil tool: $toolMsg');
          yield const LlmDone();
        }

      case MockScenario.loopTrap:
        // Always request the same tool → should be stopped by LoopDetector.
        yield LlmToolCall(
          ToolCall(id: 'call_loop_$_turn', name: 'datetime', args: {}),
        );
        yield const LlmDone(finishReason: 'tool_calls');
    }
  }

  @override
  Future<List<double>> embed(String text) async => List.filled(8, 0.1);
}

enum MockScenario { plain, singleTool, multiTool, loopTrap }

/// In-memory tool executor for mock tests.
class MockToolExecutor implements ToolExecutor {
  @override
  Future<ToolResult> run(ToolCall call, ToolContext ctx) async {
    switch (call.name) {
      case 'datetime':
        return ToolResult(
          callId: call.id,
          content: '2026-11-04T10:00:00Z',
          durationMs: 1,
        );
      case 'calc':
        final expr = call.args['expression'] as String? ?? '0';
        // Very naive eval for tests only.
        final result = _evalSimple(expr);
        return ToolResult(
          callId: call.id,
          content: result.toString(),
          durationMs: 1,
        );
      default:
        return ToolResult(
          callId: call.id,
          content: 'Unknown tool: ${call.name}',
          isError: true,
        );
    }
  }

  num _evalSimple(String expr) {
    expr = expr.replaceAll(' ', '');
    if (expr.contains('+')) {
      final parts = expr.split('+');
      return num.parse(parts[0]) + num.parse(parts[1]);
    }
    if (expr.contains('-')) {
      final parts = expr.split('-');
      return num.parse(parts[0]) - num.parse(parts[1]);
    }
    return num.tryParse(expr) ?? 0;
  }
}

/// Always-allow permission gate for tests.
class AllowAllGate implements PermissionGate {
  @override
  Future<PermissionResult> check(ToolCall call, Session session) async =>
      const PermissionResult(PermissionVerdict.allowed);
}

/// Deny-all gate.
class DenyAllGate implements PermissionGate {
  @override
  Future<PermissionResult> check(ToolCall call, Session session) async =>
      const PermissionResult(
        PermissionVerdict.denied,
        reason: 'denied by policy',
      );
}

/// In-memory no-op memory.
class NoopMemory implements MemoryStore {
  @override
  Future<void> addMessage(Message m) async {}

  @override
  Future<List<MemoryHit>> search(String query, {int k = 8}) async => [];

  @override
  Future<void> upsertFact(Fact f) async {}

  @override
  Future<void> afterTurn(Session session) async {}
}

import 'package:agent_core/agent_core.dart';
import 'package:agent_providers/agent_providers.dart';
import 'package:test/test.dart';

/// F2 (docs/15 §3) — edit-loop guard: state machine + integrasi AgentLoop.
void main() {
  group('EditLoopGuard (state machine)', () {
    test('belum pending: semua tool lolos', () {
      final guard = EditLoopGuard();
      expect(guard.pendingVerify, isFalse);
      expect(guard.intercept(const ToolCall(id: 'c1', name: 'read_file', args: {})), isNull);
    });

    test('patch_file sukses -> tool lain ditahan, verify_project melepas', () {
      final guard = EditLoopGuard();
      guard.observe('patch_file', false);
      expect(guard.pendingVerify, isTrue);
      expect(guard.intercept(const ToolCall(id: 'c1', name: 'verify_project', args: {})), isNull);
      expect(guard.intercept(const ToolCall(id: 'c2', name: 'read_file', args: {})), isNotNull);
      guard.observe('verify_project', false);
      expect(guard.pendingVerify, isFalse);
      expect(guard.intercept(const ToolCall(id: 'c3', name: 'read_file', args: {})), isNull);
    });

    test('patch_file gagal -> tidak ada tahanan', () {
      final guard = EditLoopGuard();
      guard.observe('patch_file', true);
      expect(guard.pendingVerify, isFalse);
    });

    test('verify_project gagal -> tetap menahan', () {
      final guard = EditLoopGuard();
      guard.observe('patch_file', false);
      guard.observe('verify_project', true);
      expect(guard.pendingVerify, isTrue);
      expect(guard.intercept(const ToolCall(id: 'c1', name: 'grep', args: {})), isNotNull);
    });

    test('reset() membersihkan tahanan', () {
      final guard = EditLoopGuard();
      guard.observe('patch_file', false);
      guard.reset();
      expect(guard.pendingVerify, isFalse);
    });
  });

  group('AgentLoop + edit loop guard', () {
    test('tool lain ditahan sampai verify_project sukses', () async {
      final executed = <String>[];
      final executor = _ScriptExecutor(executed);
      final provider = _ScriptedProvider([
        [_evTool('patch_file'), const LlmDone()],
        [_evTool('read_file'), const LlmDone()],
        [_evTool('verify_project'), const LlmDone()],
        [const LlmTextDelta('selesai'), const LlmDone()],
      ]);
      final loop = _loop(provider, executor, editLoopVerify: true);
      await loop.handle(
        const InboundMessage(
          channel: 'cli',
          userKey: 'u1',
          sessionKey: 'cli:u1',
          text: 'perbaiki lalu verifikasi',
        ),
        Session(id: 's1', channel: 'cli', userKey: 'u1'),
      );

      expect(executed, ['patch_file', 'verify_project']);
      expect(loop.lastTurnSucceeded, isTrue);
    });

    test('guard nonaktif: perilaku lama tanpa tahanan', () async {
      final executed = <String>[];
      final executor = _ScriptExecutor(executed);
      final provider = _ScriptedProvider([
        [_evTool('patch_file'), const LlmDone()],
        [_evTool('read_file'), const LlmDone()],
        [const LlmTextDelta('selesai'), const LlmDone()],
      ]);
      final loop = _loop(provider, executor);
      await loop.handle(
        const InboundMessage(
          channel: 'cli',
          userKey: 'u1',
          sessionKey: 'cli:u1',
          text: 'perbaiki lalu baca',
        ),
        Session(id: 's1', channel: 'cli', userKey: 'u1'),
      );

      expect(executed, ['patch_file', 'read_file']);
      expect(loop.lastTurnSucceeded, isTrue);
    });
  });
}

LlmToolCall _evTool(String name) => LlmToolCall(
      ToolCall(id: 'c_$name', name: name, args: const {}),
    );

AgentLoop _loop(
  _ScriptedProvider provider,
  _ScriptExecutor executor, {
  bool editLoopVerify = false,
}) =>
    AgentLoop(
      router:
          Router(providers: {'x': provider}, defaultProviderId: 'x'),
      contextBuilder: ContextBuilder(),
      compactor: Compactor(),
      gate: AllowAllGate(),
      executor: executor,
      memory: NoopMemory(),
      reply: (m, text) async {},
      editLoopVerify: editLoopVerify,
      config: const AgentConfig(maxIterations: 8, maxToolCalls: 10),
    );

class _ScriptedProvider implements LlmProvider {
  _ScriptedProvider(this.turns);

  final List<List<LlmEvent>> turns;
  int _turn = 0;

  @override
  String get id => 'scripted';

  @override
  Capabilities get capabilities => const Capabilities(toolCalling: true);

  @override
  Stream<LlmEvent> chat(ChatRequest req) async* {
    if (_turn < turns.length) {
      for (final e in turns[_turn++]) {
        yield e;
      }
    } else {
      yield const LlmDone();
    }
  }

  @override
  Future<List<double>> embed(String text) async => const [];
}

class _ScriptExecutor implements ToolExecutor {
  _ScriptExecutor(this.executed);

  final List<String> executed;

  @override
  Future<ToolResult> run(ToolCall call, ToolContext ctx) async {
    executed.add(call.name);
    return ToolResult(callId: call.id, content: 'ok');
  }
}

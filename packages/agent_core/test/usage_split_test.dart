import 'package:agent_core/agent_core.dart';
import 'package:agent_providers/agent_providers.dart';
import 'package:test/test.dart';

/// S20-C — usage split: rincian prompt/completion tokens terakumulasi di
/// BudgetGuard dan diekspos AgentLoop sebagai lastPromptTokens /
/// lastCompletionTokens.
void main() {
  group('BudgetGuard split token', () {
    late BudgetGuard guard;

    setUp(() {
      guard = BudgetGuard()
        ..reset(
          maxIterations: 10,
          maxTokens: 1000,
          maxWallClockSec: 60,
          maxToolCalls: 10,
        );
    });

    test('TokenUsage(prompt, completion) tercatat terpisah dan total', () {
      guard.addTokens(const TokenUsage(prompt: 3, completion: 5));
      expect(guard.promptTokens, 3);
      expect(guard.completionTokens, 5);
      expect(guard.tokensUsed, 8);
    });

    test('total eksplisit menang atas prompt+completion', () {
      guard.addTokens(const TokenUsage(total: 9, prompt: 2, completion: 2));
      expect(guard.tokensUsed, 9);
      expect(guard.promptTokens, 2);
      expect(guard.completionTokens, 2);
    });

    test('akumulasi lintas turn', () {
      guard.addTokens(const TokenUsage(prompt: 4, completion: 1));
      guard.addTokens(const TokenUsage(prompt: 6, completion: 3));
      expect(guard.promptTokens, 10);
      expect(guard.completionTokens, 4);
      expect(guard.tokensUsed, 14);
    });

    test('reset mengosongkan rincian', () {
      guard.addTokens(const TokenUsage(prompt: 7, completion: 2));
      guard.reset(
        maxIterations: 5,
        maxTokens: 100,
        maxWallClockSec: 30,
        maxToolCalls: 5,
      );
      expect(guard.promptTokens, 0);
      expect(guard.completionTokens, 0);
      expect(guard.tokensUsed, 0);
    });
  });

  group('AgentLoop usage split ekspos', () {
    test('lastPromptTokens / lastCompletionTokens dari provider mock',
        () async {
      final mock = MockLlmProvider(scenario: MockScenario.plain);
      final loop = AgentLoop(
        router: Router(providers: {'mock': mock}, defaultProviderId: 'mock'),
        contextBuilder: ContextBuilder(),
        compactor: Compactor(),
        gate: AllowAllGate(),
        executor: MockToolExecutor(),
        memory: NoopMemory(),
        reply: (m, text) async {},
      );
      await loop.handle(
        const InboundMessage(
          channel: 'cli',
          userKey: 'user1',
          sessionKey: 'cli:user1',
          text: 'Halo',
        ),
        Session(id: 's20-c', channel: 'cli', userKey: 'user1'),
      );
      expect(loop.lastPromptTokens, 20);
      expect(loop.lastCompletionTokens, 10);
      expect(loop.lastTokensUsed, 30);
    });
  });
}

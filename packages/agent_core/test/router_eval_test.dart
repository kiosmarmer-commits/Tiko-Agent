import 'package:agent_core/agent_core.dart';
import 'package:test/test.dart';

class _MockProvider extends LlmProvider {
  _MockProvider(this.pid, {this.toolCalling = false});

  final String pid;
  final bool toolCalling;

  @override
  String get id => pid;

  @override
  Capabilities get capabilities =>
      Capabilities(toolCalling: toolCalling, streaming: false);

  @override
  Stream<LlmEvent> chat(ChatRequest req) => const Stream.empty();
}

void main() {
  final router = Router(
    providers: {
      'mock-local': _MockProvider('mock-local', toolCalling: true),
      'mock-chat': _MockProvider('mock-chat'),
    },
    defaultProviderId: 'mock-local',
  );

  test('dataset berisi 50 kalimat dengan id unik', () {
    expect(indonesianRouterEval50, hasLength(50));
    final ids = indonesianRouterEval50.map((c) => c.id).toSet();
    expect(ids, hasLength(50));
  });

  test('semua kalimat dirouting sesuai ekspektasi (akurasi 100%)', () async {
    final results = await RouterEvalHarness.run(
      router,
      indonesianRouterEval50,
    );
    final failed = RouterEvalHarness.failures(results);
    expect(
      failed.map((f) => '${f.caseId}: ${f.detail}').join('\n'),
      isEmpty,
    );
    expect(RouterEvalHarness.accuracy(results), 1.0);
  });

  test('routing deterministik antar-eksekusi', () async {
    final first = await RouterEvalHarness.run(
      router,
      indonesianRouterEval50,
    );
    final second = await RouterEvalHarness.run(
      router,
      indonesianRouterEval50,
    );
    expect(
      first.map((r) => r.passed).toList(),
      second.map((r) => r.passed).toList(),
    );
  });
}

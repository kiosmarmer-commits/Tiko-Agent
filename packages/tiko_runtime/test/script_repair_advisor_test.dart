import 'package:agent_core/agent_core.dart';
import 'package:agent_tools/agent_tools.dart';
import 'package:tiko_runtime/tiko_runtime.dart';
import 'package:test/test.dart';

class _ScriptedLlm implements LlmProvider {
  _ScriptedLlm(this.response);

  final String response;
  ChatRequest? lastRequest;

  @override
  String get id => 'scripted-advisor';

  @override
  Capabilities get capabilities =>
      const Capabilities(toolCalling: false, streaming: true, maxContext: 8192);

  @override
  Stream<LlmEvent> chat(ChatRequest req) async* {
    lastRequest = req;
    yield LlmTextDelta(response);
  }

  @override
  Future<List<double>> embed(String text) async => const [];
}

class _ErrorLlm implements LlmProvider {
  const _ErrorLlm();

  @override
  String get id => 'error-advisor';

  @override
  Capabilities get capabilities =>
      const Capabilities(toolCalling: false, streaming: true, maxContext: 8192);

  @override
  Stream<LlmEvent> chat(ChatRequest req) async* {
    yield const LlmError('provider mati');
  }

  @override
  Future<List<double>> embed(String text) async => const [];
}

ScriptRepairInput _input() => const ScriptRepairInput(
      source: 'print(x)',
      entryFile: 'run.py',
      command: ['python3', 'run.py'],
      argsJson: '',
      attempt: 1,
      maxAttempts: 3,
      exitCode: 1,
      stdout: '',
      stderr: 'NameError: name x is not defined',
    );

void main() {
  group('LlmScriptRepairAdvisor', () {
    test('mengekstrak blok kode fenced terakhir', () async {
      final llm = _ScriptedLlm('''
Analisis: variabel x tidak didefinisikan.

```python
print("x didefinisikan")
```

Ini blok jawaban final:

```python
print("jawaban benar")
```
''');
      final advisor = LlmScriptRepairAdvisor(llm);
      final patch = await advisor.proposePatch(_input());
      expect(patch, 'print("jawaban benar")');
      expect(llm.lastRequest!.stream, isFalse);
      expect(llm.lastRequest!.temperature, 0.0);
    });

    test('balasan tanpa fence dipakai utuh (fallback)', () async {
      final llm = _ScriptedLlm('print("tanpa fence")');
      final advisor = LlmScriptRepairAdvisor(llm);
      expect(await advisor.proposePatch(_input()), 'print("tanpa fence")');
    });

    test('UNFIXABLE → ScriptRepairException', () async {
      final llm = _ScriptedLlm('UNFIXABLE');
      final advisor = LlmScriptRepairAdvisor(llm);
      expect(
        () => advisor.proposePatch(_input()),
        throwsA(isA<ScriptRepairException>()),
      );
    });

    test('balasan kosong → ScriptRepairException', () async {
      final llm = _ScriptedLlm('   ');
      final advisor = LlmScriptRepairAdvisor(llm);
      expect(
        () => advisor.proposePatch(_input()),
        throwsA(isA<ScriptRepairException>()),
      );
    });

    test('LLM error (bukan teks) → ScriptRepairException', () async {
      final advisor = LlmScriptRepairAdvisor(const _ErrorLlm());
      expect(
        () => advisor.proposePatch(_input()),
        throwsA(isA<ScriptRepairException>()),
      );
    });

    test('prompt memuat source, stderr, dan nomor percobaan', () async {
      final llm = _ScriptedLlm('print("ok")');
      final advisor = LlmScriptRepairAdvisor(llm);
      await advisor.proposePatch(_input());
      final user = llm.lastRequest!.messages.last.content;
      expect(user, contains('print(x)'));
      expect(user, contains('NameError'));
      expect(user, contains('1/3'));
    });
  });
}

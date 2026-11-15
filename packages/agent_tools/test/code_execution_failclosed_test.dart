import 'package:agent_core/agent_core.dart';
import 'package:agent_tools/agent_tools.dart';
import 'package:test/test.dart';

class _FakeProvider implements CodeExecutionProvider {
  @override
  String get name => 'fake';

  @override
  List<ExecutionLanguage> get supportedLanguages => ExecutionLanguage.values;

  @override
  Future<bool> isAvailable() async => true;

  @override
  Future<CodeExecutionResult> execute({
    required String code,
    required ExecutionLanguage language,
    required CodeExecutionConfig config,
    String? workingDirectory,
    Map<String, String>? environment,
    Duration? timeout,
  }) async {
    return const CodeExecutionResult(success: true, output: 'fake-ok');
  }
}

ToolContext _ctx() => ToolContext(
      session: Session(id: 's1', channel: 'test', userKey: 'u'),
      workspacePath: '/tmp',
    );

void main() {
  test('tanpa sandbox dan tanpa provider: run ditolak fail-closed', () async {
    final tool = CodeExecutionTool(
      config: const CodeExecutionConfig(),
      sandbox: null,
    );
    final result = await tool.run({'code': 'print(1)'}, _ctx());
    expect(result.isError, isTrue);
    expect(result.content, contains('fail-closed'));
  });

  test('sandbox none: run ditolak fail-closed', () async {
    final tool = CodeExecutionTool(
      config: const CodeExecutionConfig(),
      sandbox: SandboxRunner(kind: SandboxKind.none, workspacePath: '/tmp'),
    );
    final result = await tool.run({'code': 'print(1)'}, _ctx());
    expect(result.isError, isTrue);
    expect(result.content, contains('fail-closed'));
  });

  test('LocalCodeExecutionProvider menolak config default (opt-in belum dibuka)',
      () async {
    final provider = LocalCodeExecutionProvider();
    final result = await provider.execute(
      code: 'print(1)',
      language: ExecutionLanguage.python,
      config: const CodeExecutionConfig(),
    );
    expect(result.success, isFalse);
    expect(result.error, contains('fail-closed'));
  });

  test('LocalCodeExecutionProvider tidak ditolak guard saat opt-in eksplisit',
      () async {
    final provider = LocalCodeExecutionProvider();
    final result = await provider.execute(
      code: 'print("halo")',
      language: ExecutionLanguage.python,
      config: const CodeExecutionConfig(
        allowFileWrite: true,
        allowNetworkAccess: true,
      ),
    );
    // Eksekusi nyata bergantung interpreter di host; cukup pastikan tidak
    // ditolak oleh guard fail-closed.
    expect(result.error, isNot(contains('ditolak (fail-closed)')));
  });

  test('provider eksplisit tetap berjalan meski sandbox none (jalur opt-in)',
      () async {
    final tool = CodeExecutionTool(
      config: const CodeExecutionConfig(),
      provider: _FakeProvider(),
      sandbox: SandboxRunner(kind: SandboxKind.none, workspacePath: '/tmp'),
    );
    final result = await tool.run({'code': 'print(1)'}, _ctx());
    expect(result.isError, isFalse);
    expect(result.content, contains('fake-ok'));
  });
}

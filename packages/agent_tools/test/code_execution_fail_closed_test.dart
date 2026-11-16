import 'dart:convert';
import 'dart:io';

import 'package:agent_core/agent_core.dart';
import 'package:agent_tools/src/code_execution.dart';
import 'package:agent_tools/src/sandbox.dart';
import 'package:test/test.dart';

ToolContext _ctx() => ToolContext(
      session: Session(id: 's1', channel: 'test', userKey: 'u'),
      workspacePath: Directory.systemTemp.createTempSync('tiko-a5').path,
    );

void main() {
  test('fail-closed: tanpa sandbox, eksekusi kode ditolak (tanpa fallback lokal)',
      () async {
    final tool = CodeExecutionTool(
      config: const CodeExecutionConfig(
        allowedLanguages: [ExecutionLanguage.bash],
      ),
      sandbox: SandboxRunner(kind: SandboxKind.none),
      workingDirectory: Directory.systemTemp.createTempSync('tiko-a5').path,
    );

    final res = await tool.run(
      {'code': 'echo pwned', 'language': 'bash'},
      _ctx(),
    );

    expect(res.isError, isTrue);
    final payload = jsonDecode(res.content) as Map<String, dynamic>;
    expect(payload['success'], isFalse);
    expect('$payload', contains('fail-closed'));
  });

  test('fail-closed: sandbox null juga ditolak', () async {
    final tool = CodeExecutionTool(
      config: const CodeExecutionConfig(
        allowedLanguages: [ExecutionLanguage.bash],
      ),
      workingDirectory: Directory.systemTemp.createTempSync('tiko-a5').path,
    );

    final res = await tool.run(
      {'code': 'echo pwned', 'language': 'bash'},
      _ctx(),
    );

    expect(res.isError, isTrue);
    expect(res.content, contains('fail-closed'));
  });

  test('opt-in eksplisit allowUnsafeLocalExecution mengizinkan eksekusi lokal',
      () async {
    final tool = CodeExecutionTool(
      config: const CodeExecutionConfig(
        allowedLanguages: [ExecutionLanguage.bash],
        allowUnsafeLocalExecution: true,
      ),
      sandbox: SandboxRunner(kind: SandboxKind.none),
      workingDirectory: Directory.systemTemp.createTempSync('tiko-a5').path,
    );

    final res = await tool.run(
      {'code': 'echo tiko-ok', 'language': 'bash'},
      _ctx(),
    );

    final payload = jsonDecode(res.content) as Map<String, dynamic>;
    expect(payload['success'], isTrue);
    expect(payload['output'], contains('tiko-ok'));
  });

  test('provider eksplisit tetap dihormati meski sandbox none', () async {
    final tool = CodeExecutionTool(
      config: const CodeExecutionConfig(
        allowedLanguages: [ExecutionLanguage.bash],
      ),
      provider: LocalCodeExecutionProvider(),
      sandbox: SandboxRunner(kind: SandboxKind.none),
      workingDirectory: Directory.systemTemp.createTempSync('tiko-a5').path,
    );

    final res = await tool.run(
      {'code': 'echo explicit', 'language': 'bash'},
      _ctx(),
    );

    final payload = jsonDecode(res.content) as Map<String, dynamic>;
    expect(payload['success'], isTrue);
    expect(payload['output'], contains('explicit'));
  });
}

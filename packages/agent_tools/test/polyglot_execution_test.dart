import 'package:agent_core/agent_core.dart';
import 'package:agent_tools/agent_tools.dart';
import 'package:test/test.dart';

/// Hello-world snippet per language, printing a shared marker.
const _marker = 'OK_TIKO_POLYGLOT';
const _snippets = <ExecutionLanguage, String>{
  ExecutionLanguage.python: 'print("$_marker")',
  ExecutionLanguage.javascript: 'console.log("$_marker");',
  ExecutionLanguage.bash: 'echo "$_marker"',
  ExecutionLanguage.dart: "void main() { print('$_marker'); }",
  ExecutionLanguage.java:
      'public class Script { public static void main(String[] args) '
      '{ System.out.println("$_marker"); } }',
  ExecutionLanguage.go:
      'package main\nimport "fmt"\nfunc main() { fmt.Println("$_marker") }',
  ExecutionLanguage.c:
      '#include <stdio.h>\nint main(void) { puts("$_marker"); return 0; }',
  ExecutionLanguage.cpp:
      '#include <iostream>\nint main() { std::cout << "$_marker" << std::endl; }',
  ExecutionLanguage.rust: 'fn main() { println!("$_marker"); }',
};

void main() {
  test('enum model: needsCompile, runArgv, compileAndRun', () {
    expect(ExecutionLanguage.python.needsCompile, isFalse);
    expect(ExecutionLanguage.c.needsCompile, isTrue);
    expect(ExecutionLanguage.rust.needsCompile, isTrue);
    expect(ExecutionLanguage.dart.runArgv('a.dart'), ['dart', 'run', 'a.dart']);
    expect(ExecutionLanguage.go.runArgv('a.go'), ['go', 'run', 'a.go']);
    expect(
      ExecutionLanguage.java.runArgv('script.java'),
      ['java', 'script.java'],
    );
    expect(
      ExecutionLanguage.c.compileAndRun('script.c'),
      contains('gcc -O1 "script.c" -o tiko_prog && ./tiko_prog'),
    );
    expect(() => ExecutionLanguage.python.compileAndRun('a.py'),
        throwsUnsupportedError);
    expect(
      ExecutionLanguage.values.every((l) => l.dockerImage.isNotEmpty),
      isTrue,
    );
  });

  test('fromExtension mengenali ekstensi baru', () {
    expect(ExecutionLanguage.fromExtension('main.go'), ExecutionLanguage.go);
    expect(ExecutionLanguage.fromExtension('main.rs'), ExecutionLanguage.rust);
    expect(ExecutionLanguage.fromExtension('main.cc'), ExecutionLanguage.cpp);
    expect(
      ExecutionLanguage.fromExtension('A.scala'),
      ExecutionLanguage.python,
    );
  });

  group('LocalCodeExecutionProvider polyglot (availability-gated)', () {
    for (final lang in ExecutionLanguage.values) {
      if (lang.needsCompile) continue;
      test('interpreted ${lang.name} fail-soft / hijau sesuai host', () async {
        final available =
            await LocalCodeExecutionProvider.interpreterAvailable(lang);
        final provider = LocalCodeExecutionProvider();
        final result = await provider.execute(
          code: _snippets[lang]!,
          language: lang,
          config: const CodeExecutionConfig(
            timeoutSeconds: 120,
            allowUnsafeLocalExecution: true,
          ),
        );
        if (available) {
          expect(result.success, isTrue, reason: result.error);
          expect(result.output, contains(_marker));
        } else {
          expect(result.success, isFalse);
          expect(result.error, isNotEmpty);
        }
      });
    }

    for (final lang in ExecutionLanguage.values) {
      if (!lang.needsCompile) continue;
      test('compiled ${lang.name} compile-then-run sesuai host', () async {
        final available =
            await LocalCodeExecutionProvider.interpreterAvailable(lang);
        final provider = LocalCodeExecutionProvider();
        final result = await provider.execute(
          code: _snippets[lang]!,
          language: lang,
          config: const CodeExecutionConfig(
            timeoutSeconds: 180,
            allowUnsafeLocalExecution: true,
          ),
        );
        if (available) {
          expect(result.success, isTrue, reason: result.error);
          expect(result.output, contains(_marker));
        } else {
          expect(result.success, isFalse);
          expect(result.error, isNotEmpty);
        }
      });
    }
  });

  test('tool menolak bahasa di luar allowedLanguages (fail-closed)', () async {
    final provider = LocalCodeExecutionProvider();
    final tool = CodeExecutionTool(
      provider: provider,
      config: const CodeExecutionConfig(
        allowedLanguages: [ExecutionLanguage.python],
        allowUnsafeLocalExecution: true,
      ),
    );
    final ctx = ToolContext(
      session: Session(id: 's', channel: 'test', userKey: 'u'),
      workspacePath: '.',
    );
    final r = await tool.run(
      {'code': 'int main(){return 0;}', 'language': 'c'},
      ctx,
    );
    expect(r.isError, isTrue);
    expect(r.content, contains('not allowed'));
  });

  test('schema language enum memuat semua bahasa F8.3', () {
    final tool = CodeExecutionTool();
    final schema = tool.spec.inputSchema;
    final enumValues = (schema['properties'] as Map)['language']['enum'];
    for (final lang in ExecutionLanguage.values) {
      expect(enumValues, contains(lang.name));
    }
  });
}

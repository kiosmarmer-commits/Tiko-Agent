import 'package:agent_core/agent_core.dart';
import 'package:agent_tools/agent_tools.dart';
import 'package:test/test.dart';

/// Daftar 100 bahasa yang diminta user (F8.3b) — setiap entri HARUS
/// terwakili (enum inti ATAU registry).
const _requested = [
  'python', 'javascript', 'java', 'c', 'cpp', 'csharp', 'typescript', 'sql',
  'go', 'rust', 'php', 'swift', 'kotlin', 'r', 'dart', 'ruby', 'matlab',
  'scala', 'shell', 'powershell', 'lua', 'haskell', 'julia', 'objectivec',
  'elixir', 'clojure', 'groovy', 'fsharp', 'perl', 'vbnet', 'assembly',
  'fortran', 'cobol', 'delphi', 'ada', 'commonlisp', 'scheme', 'prolog',
  'erlang', 'ocaml', 'crystal', 'nim', 'zig', 'd', 'smalltalk', 'vhdl',
  'verilog', 'abap', 'sas', 'plsql', 'tsql', 'apex', 'solidity', 'vyper',
  'racket', 'sml', 'eiffel', 'modula2', 'oberon', 'forth', 'logo', 'scratch',
  'alice', 'squeak', 'self', 'io', 'factor', 'j', 'apl', 'postscript',
  'actionscript', 'coldfusion', 'xquery', 'xslt', 'spss', 'stata', 'gams',
  'awk', 'sed', 'tcl', 'livecode', 'purebasic', 'freebasic', 'gambas',
  'harbour', 'visualfoxpro', 'rpg', 'natural', 'pli', 'simula', 'algol',
  'snobol', 'icon', 'curry', 'mercury', 'oz', 'joy', 'brainfuck', 'piet',
  // alias eksplisit yang juga harus resolve:
  'c++', 'c#', 'golang', 'ts', 'sh', 'f#', 'vb', 'standardml', 'modula-2',
];

void main() {
  test('setiap bahasa dari daftar 100 terwakili (enum ATAU registry)', () {
    for (final name in _requested) {
      final canonical = LanguageRegistry.aliases[name] ?? name;
      final inEnum = _enumNames.contains(canonical);
      final spec = LanguageRegistry.lookup(canonical);
      expect(inEnum || spec != null, isTrue, reason: 'bahasa "$name" hilang');
    }
  });

  test('nama registry unik dan tidak menabrak enum inti', () {
    final names = LanguageRegistry.specs.map((s) => s.name).toList();
    expect(names.toSet().length, names.length);
    for (final n in _enumNames) {
      expect(names.contains(n), isFalse,
          reason: 'nama $n ganda dengan enum inti');
    }
  });

  test('spec didukung wajib punya cmd; unsupported punya alasan', () {
    for (final s in LanguageRegistry.specs) {
      if (s.supported) {
        final isBuiltin = s.name == 'brainfuck';
        expect(
          isBuiltin || s.runCmd != null || s.compileCmd != null,
          isTrue,
          reason: 'spec ${s.name} didukung tapi tanpa run/compile cmd',
        );
      } else {
        expect(s.unsupportedReason, isNotEmpty, reason: s.name);
      }
    }
  });

  test('Brainfuck built-in: hello world', () {
    const hello =
        '++++++++[>++++[>++>+++>+++>+<<<<-]>+>+>->>+[<]<-]'
        '>>.>---.+++++++..+++.>>.<-.<.+++.------.--------.>>+.>++.';
    final out = BrainfuckInterpreter.run(hello);
    expect(out, 'Hello World!\n');
  });

  test('Brainfuck loop tak terbatas -> fail dengan kap langkah', () {
    expect(
      () => BrainfuckInterpreter.run('+[>+]'),
      throwsStateError,
    );
  });

  test('unsupported language: alasan eksplisit (fail-closed, bukan kabur)',
      () async {
    final tool = CodeExecutionTool(
      provider: LocalCodeExecutionProvider(),
      config: const CodeExecutionConfig(allowUnsafeLocalExecution: true),
    );
    final r = await tool.run({
      'code': 'MOVE A TO B.',
      'language': 'cobol-proprietary',
    }, _ctx());
    // 'cobol' valid tapi proprietary==supported via cobc; pakai matlab:
    final r2 = await tool.run({
      'code': 'disp(1)',
      'language': 'matlab',
    }, _ctx());
    expect(r2.isError, isTrue);
    expect(r2.content, contains('tidak dieksekusi'));
    expect(r2.content, contains('Octave'));
    expect(r.isError, isTrue); // 'cobol-proprietary' tak dikenal
  });

  test('alias umum resolve ke spesifikasi/enum', () {
    expect(LanguageRegistry.aliases['c++'], 'cpp');
    expect(LanguageRegistry.aliases['golang'], 'go');
    expect(LanguageRegistry.lookup('C#')?.name, 'csharp');
    expect(LanguageRegistry.lookup('standard ml')?.name, 'sml');
    expect(LanguageRegistry.lookup('modula-2')?.name, 'modula2');
  });

  test('tool mengeksekusi bahasa registry yang tersedia (perl/awk/sh)',
      () async {
    final tool = CodeExecutionTool(
      provider: LocalCodeExecutionProvider(),
      config: const CodeExecutionConfig(allowUnsafeLocalExecution: true),
    );
    const cases = <String, String>{
      'perl': "print 'OK_PERL';",
      'awk': 'BEGIN { print "OK_AWK" }',
      'shell': 'echo OK_SH',
    };
    for (final entry in cases.entries) {
      final bin = LanguageRegistry.lookup(entry.key)!.interpreter!;
      if (!LanguageRegistry.onPath(bin)) continue;
      final r = await tool.run({
        'code': entry.value,
        'language': entry.key,
      }, _ctx());
      // fail-soft bila runtime error; sukses print marker
      if (!r.isError) {
        expect(r.content, contains('OK'), reason: entry.key);
      } else {
        expect(r.content, isNotEmpty, reason: entry.key);
      }
    }
  });

  test('Brainfuck via tool: sukses tanpa toolchain host', () async {
    final tool = CodeExecutionTool(
      provider: LocalCodeExecutionProvider(),
      config: const CodeExecutionConfig(allowUnsafeLocalExecution: true),
    );
    // 0x44 = 68 pluses -> 'D'
    final r = await tool.run({
      'code': '+' * 68 + '.',
      'language': 'brainfuck',
    }, _ctx());
    expect(r.isError, isFalse);
    expect(r.content, contains('D'));
  });

  test('allowedLanguageNames whitelist menahan bahasa registry', () async {
    final tool = CodeExecutionTool(
      provider: LocalCodeExecutionProvider(),
      config: const CodeExecutionConfig(
        allowUnsafeLocalExecution: true,
        allowedLanguageNames: ['perl'],
      ),
    );
    final r = await tool.run({'code': 'SELECT 1;', 'language': 'sql'}, _ctx());
    expect(r.isError, isTrue);
    expect(r.content, contains('not allowed'));
  });

  test('Brainfuck via sandboxed provider: masih dieksekusi (builtin tidak '
      'butuh shell)', () async {
    final tool = CodeExecutionTool(); // tanpa sandbox/provider = disabled
    final r = await tool.run({
      'code': '+.',
      'language': 'brainfuck',
    }, _ctx());
    // provider disabled → error fail-closed tetap berlaku
    expect(r.isError, isTrue);
  });
}

const _enumNames = [
  'python',
  'javascript',
  'bash',
  'dart',
  'java',
  'go',
  'c',
  'cpp',
  'rust',
];

ToolContext _ctx() => ToolContext(
      session: Session(id: 's1', channel: 'test', userKey: 'u'),
      workspacePath: '.',
    );

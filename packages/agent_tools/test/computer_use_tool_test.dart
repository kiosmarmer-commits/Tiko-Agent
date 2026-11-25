import 'dart:io';

import 'package:agent_core/agent_core.dart';
import 'package:agent_tools/agent_tools.dart';
import 'package:test/test.dart';

/// Runner palsu: mencatat argv, balas template, kontrol binary eksis.
class FakeRunner implements ComputerProcessRunner {
  final Set<String> binaries;
  final int exitCode;
  final String stderr;
  final List<List<String>> calls = [];

  FakeRunner({
    this.binaries = const {},
    this.exitCode = 0,
    this.stderr = '',
  });

  @override
  Future<ComputerProcessResult> run(
    List<String> argv, {
    Duration timeout = const Duration(seconds: 20),
  }) async {
    calls.add(List.of(argv));
    // Simulasi engine screenshot: tulis file PNG target bila exit sukses.
    if (exitCode == 0 && argv.isNotEmpty && argv.last.endsWith('.png')) {
      File(argv.last)..createSync(recursive: true)..writeAsBytesSync(<int>[137]);
    }
    return ComputerProcessResult(exitCode: exitCode, stdout: '', stderr: stderr);
  }

  @override
  bool binaryExists(String bin) => binaries.contains(bin);
}

void main() {
  late Directory root;
  late ToolContext ctx;

  setUp(() {
    root = Directory.systemTemp.createTempSync('tiko_computer_use_');
    ctx = ToolContext(
      session: Session(id: 's20-a', channel: 'cli', userKey: 'u1'),
      workspacePath: root.path,
    );
  });

  tearDown(() {
    root.deleteSync(recursive: true);
  });

  group('validasi argumen', () {
    test('action tidak dikenal -> error jujur', () async {
      final tool = ComputerUseTool(runner: FakeRunner());
      final res = await tool.run({'action': 'dance'}, ctx);
      expect(res.isError, isTrue);
      expect(res.content, contains('action tidak dikenal "dance"'));
    });

    test('click tanpa koordinat -> error', () async {
      final tool = ComputerUseTool(
          runner: FakeRunner(binaries: {'xdotool'}));
      final res = await tool.run({'action': 'click'}, ctx);
      expect(res.isError, isTrue);
      expect(res.content, contains('x dan y wajib integer'));
    });

    test('click koordinat out-of-range -> error', () async {
      final tool = ComputerUseTool(
          runner: FakeRunner(binaries: {'xdotool'}));
      final res = await tool.run({'action': 'click', 'x': 99999, 'y': 10}, ctx);
      expect(res.isError, isTrue);
      expect(res.content, contains('0..65535'));
    });

    test('button tidak valid -> error', () async {
      final tool = ComputerUseTool(
          runner: FakeRunner(binaries: {'xdotool'}));
      final res = await tool.run(
          {'action': 'click', 'x': 5, 'y': 6, 'button': 'extra'}, ctx);
      expect(res.isError, isTrue);
      expect(res.content, contains('left | middle | right'));
    });

    test('type tanpa teks -> error', () async {
      final tool = ComputerUseTool(
          runner: FakeRunner(binaries: {'xdotool'}));
      final res = await tool.run({'action': 'type'}, ctx);
      expect(res.isError, isTrue);
      expect(res.content, contains('text wajib diisi'));
    });

    test('key combo berisi karakter ilegal -> error', () async {
      final tool = ComputerUseTool(
          runner: FakeRunner(binaries: {'xdotool'}));
      final res = await tool.run({'action': 'key', 'combo': 'ctrl;rm -rf'}, ctx);
      expect(res.isError, isTrue);
      expect(res.content, contains('combo wajib diisi'));
    });

    test('scroll clicks di luar -20..20 -> error', () async {
      final tool = ComputerUseTool(
          runner: FakeRunner(binaries: {'xdotool'}));
      final res = await tool.run(
          {'action': 'scroll', 'x': 1, 'y': 2, 'clicks': 99}, ctx);
      expect(res.isError, isTrue);
      expect(res.content, contains('-20..20'));
    });
  });

  group('engine tidak tersedia (fail-closed)', () {
    test('screenshot tanpa engine -> error + hint', () async {
      final tool = ComputerUseTool(runner: FakeRunner(exitCode: 1));
      final res = await tool.run({'action': 'screenshot'}, ctx);
      expect(res.isError, isTrue);
      expect(res.content, contains('tidak ada engine screenshot'));
    });

    test('click tanpa engine -> error + hint', () async {
      final tool = ComputerUseTool(runner: FakeRunner(exitCode: 1));
      final res = await tool.run({'action': 'click', 'x': 1, 'y': 2}, ctx);
      expect(res.isError, isTrue);
      expect(res.content, contains('tidak ada engine input'));
    });
  });

  group('xdotool argv array (tanpa interpreter shell)', () {
    test('click memakai satu argv xdotool', () async {
      final runner = FakeRunner(binaries: {'xdotool'});
      final tool = ComputerUseTool(runner: runner);
      final res = await tool.run(
          {'action': 'click', 'x': 10, 'y': 20, 'button': 'right'}, ctx);
      expect(res.isError, isFalse);
      expect(runner.calls.single.first, 'xdotool');
      expect(
          runner.calls.single,
          ['xdotool', 'mousemove', '10', '20', 'click', '3']);
      expect(res.content, contains('click 10,20 ok'));
    });

    test('double click memakai --repeat 2', () async {
      final runner = FakeRunner(binaries: {'xdotool'});
      final tool = ComputerUseTool(runner: runner);
      final res = await tool.run(
          {'action': 'click', 'x': 1, 'y': 2, 'double': true}, ctx);
      expect(res.isError, isFalse);
      expect(runner.calls.single, containsAll(['--repeat', '2']));
    });

    test('key memakai single argv tanpa flag duplikat', () async {
      final runner = FakeRunner(binaries: {'xdotool'});
      final tool = ComputerUseTool(runner: runner);
      final res = await tool.run({'action': 'key', 'combo': 'ctrl+s'}, ctx);
      expect(res.isError, isFalse);
      expect(runner.calls.single,
          ['xdotool', 'key', '--clearmodifiers', 'ctrl+s']);
    });

    test('type -- lalu teks apa pun tetap argv tunggal', () async {
      final runner = FakeRunner(binaries: {'xdotool'});
      final tool = ComputerUseTool(runner: runner);
      const text = "O'Brien (rm -rf)";
      final res = await tool.run({'action': 'type', 'text': text}, ctx);
      expect(res.isError, isFalse);
      expect(
          runner.calls.single,
          [
            'xdotool',
            'type',
            '--clearmodifiers',
            '--',
            text,
          ]);
    });
  });

  group('screenshot', () {
    test('scrot sukses -> file dibuat + path dikembalikan', () async {
      final runner = FakeRunner(binaries: {'scrot'});
      final tool = ComputerUseTool(runner: runner);
      final res = await tool.run({'action': 'screenshot'}, ctx);
      expect(res.isError, isFalse);
      expect(res.content, contains('screenshot tersimpan:'));
      final dir = Directory('${root.path}/data/screenshots');
      expect(dir.existsSync(), isTrue);
      // path yang dikembalikan ada di dalam jail workspace.
      final pathMatch =
          RegExp(r'screenshot tersimpan: (\S+)').firstMatch(res.content)!;
      expect(pathMatch.group(1)!.startsWith('${root.path}/data/screenshots/'),
          isTrue);
      expect(File(pathMatch.group(1)!).existsSync(), isTrue);
      expect(runner.calls.single.first, 'scrot');
    });

    test('scrot exit non-zero -> error jujur dengan stderr', () async {
      final runner = FakeRunner(binaries: {'scrot'}, exitCode: 1,
          stderr: 'can not open display');
      final tool = ComputerUseTool(runner: runner);
      final res = await tool.run({'action': 'screenshot'}, ctx);
      expect(res.isError, isTrue);
      expect(res.content, contains('can not open display'));
    });
  });

  test('spec: risk high, timeout 60, action enum tervalidasi', () {
    final tool = ComputerUseTool(runner: FakeRunner());
    expect(tool.spec.name, 'computer_use');
    expect(tool.spec.risk, 'high');
    expect(tool.spec.timeoutSec, 60);
    expect(tool.spec.inputSchema['required'], ['action']);
  });
}

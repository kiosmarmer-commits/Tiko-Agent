import 'dart:io';

import 'package:agent_core/agent_core.dart';
import 'package:agent_tools/agent_tools.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  late VerifyProjectTool tool;
  late ToolContext ctx;

  setUp(() {
    root = Directory.systemTemp.createTempSync('tiko_verifylang_');
    tool = VerifyProjectTool(workspaceRoot: root.path);
    ctx = ToolContext(
      session: Session(id: 's-s19', channel: 'cli', userKey: 'u1'),
      workspacePath: root.path,
    );
  });

  tearDown(() {
    root.deleteSync(recursive: true);
  });

  test('detectVerifyCandidates: pubspec non-flutter -> dart analyze', () {
    File('${root.path}/pubspec.yaml').writeAsStringSync(
        'name: demo\nenvironment:\n  sdk: ^3.8.0\ndependencies:\n  path: ^1.9.0\n');
    expect(detectVerifyCandidates(root.path), ['dart analyze']);
  });

  test('detectVerifyCandidates: pubspec flutter -> flutter analyze', () {
    File('${root.path}/pubspec.yaml').writeAsStringSync(
        'name: demo\ndependencies:\n  flutter:\n    sdk: flutter\n');
    expect(detectVerifyCandidates(root.path), ['flutter analyze']);
  });

  test('detectVerifyCandidates: go.mod dan go vet', () {
    File('${root.path}/go.mod').writeAsStringSync('module demo\n');
    expect(detectVerifyCandidates(root.path), contains('go vet ./...'));
  });

  test('tanpa manifest: auto gagal jujur (bukan error kabur)', () async {
    final res = await tool.run({'auto': true}, ctx);
    expect(res.isError, isTrue);
    expect(res.content, contains('manifest'));
  });

  test('auto mode: kandidat dart analyze dieksekusi nyata', () async {
    File('${root.path}/pubspec.yaml').writeAsStringSync(
        'name: demo\nenvironment:\n  sdk: ^3.8.0\ndependencies:\n  path: ^1.9.0\n');
    Directory('${root.path}/lib').createSync();
    File('${root.path}/lib/main.dart').writeAsStringSync('void main() {}\n');
    final res = await tool.run({'auto': true, 'timeout_sec': 120}, ctx);
    expect(res.isError, isFalse);
    expect(res.content, contains('[auto] kandidat: dart analyze'));
    expect(res.content, contains('VERIFIKASI'));
  });

  test('cmd eksplisit tetap berlaku (mode lama tidak berubah)', () async {
    final res = await tool.run({'cmd': 'true'}, ctx);
    expect(res.isError, isFalse);
    expect(res.content, contains('VERIFIKASI OK'));
  });
}

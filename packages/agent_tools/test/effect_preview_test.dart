import 'dart:io';

import 'package:agent_core/agent_core.dart';
import 'package:agent_tools/agent_tools.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('tiko_preview');
  });
  tearDown(() async {
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  ToolContext ctx() => ToolContext(
        session: Session(id: 's1', channel: 'cli', userKey: 'local'),
        workspacePath: tmp.path,
      );

  test('preview write file baru', () async {
    final res = await const EffectPreviewTool().run({
      'action': 'write',
      'path': 'baru.txt',
      'content': 'satu',
    }, ctx());
    expect(res.isError, isFalse);
    expect(res.content, contains('file baru'));
    expect(File('${tmp.path}/baru.txt').existsSync(), isFalse);
  });

  test('preview write diff terhadap isi lama', () async {
    File('${tmp.path}/a.txt').writeAsStringSync('satu\n dua');
    final res = await const EffectPreviewTool().run({
      'action': 'write',
      'path': 'a.txt',
      'content': 'satu\ntiga',
    }, ctx());
    expect(res.isError, isFalse);
    expect(res.content, contains('+1 / -1'));
    expect(res.content, contains('+ tiga'));
    expect(res.content, contains('-  dua'));
    expect(File('${tmp.path}/a.txt').readAsStringSync(), 'satu\n dua');
  });

  test('preview delete file dan direktori', () async {
    File('${tmp.path}/f.txt').writeAsStringSync('isi');
    final resFile = await const EffectPreviewTool().run({
      'action': 'delete',
      'path': 'f.txt',
    }, ctx());
    expect(resFile.isError, isFalse);
    expect(resFile.content, contains('byte akan hilang'));

    Directory('${tmp.path}/d').createSync();
    File('${tmp.path}/d/x.txt').writeAsStringSync('isi');
    final resDir = await const EffectPreviewTool().run({
      'action': 'delete',
      'path': 'd',
    }, ctx());
    expect(resDir.isError, isFalse);
    expect(resDir.content, contains('file, '));

    final resMiss = await const EffectPreviewTool().run({
      'action': 'delete',
      'path': 'takada.txt',
    }, ctx());
    expect(resMiss.isError, isTrue);
  });

  test('path di luar workspace ditolak', () async {
    final res = await const EffectPreviewTool().run({
      'action': 'write',
      'path': '../luar.txt',
      'content': 'x',
    }, ctx());
    expect(res.isError, isTrue);
  });
}

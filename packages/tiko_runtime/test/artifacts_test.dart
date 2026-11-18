import 'dart:io';

import 'package:tiko_runtime/tiko_runtime.dart';
import 'package:test/test.dart';

/// GUI-P2-04: artifacts browser & diff viewer — list/read/diff workspace
/// read-only, PathSafety fail-closed, LCS diff vs `.bak`.
void main() {
  late Directory temp;
  late TikoRuntime rt;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('artifacts-test');
    final configPath = File('${temp.path}/config.yaml');
    await configPath.writeAsString('''
providers:
  mock:
    type: openai_compat
    base_url: http://127.0.0.1:1/v1
    api_key: sk-test
default_provider: mock
data_dir: ${temp.path}/data
memory:
  backend: json
logs_dir: ${temp.path}/logs
workspace: ${temp.path}/workspace
security:
  mode: ask
mcp:
  servers: []
''');
    rt = await TikoRuntime.create(configPath: configPath.path);
    addTearDown(rt.close);
  });

  tearDown(() async {
    await temp.delete(recursive: true);
  });

  test('artifactsList: file workspace + skip .git/node_modules', () async {
    final ws = Directory('${temp.path}/workspace');
    File('${ws.path}/README.md').writeAsStringSync('halo');
    Directory('${ws.path}/src').createSync();
    File('${ws.path}/src/main.dart').writeAsStringSync('void main() {}');
    Directory('${ws.path}/.git').createSync();
    File('${ws.path}/.git/config').writeAsStringSync('rahasia-repo');
    Directory('${ws.path}/node_modules').createSync(recursive: true);
    File('${ws.path}/node_modules/lib.js').writeAsStringSync('x');

    final r = rt.artifactsList();
    final paths = (r['files'] as List).map((e) => (e as Map)['path']).toList();
    expect(paths, containsAll(['README.md', 'src/main.dart']));
    expect(paths.any((p) => '$p'.contains('.git')), isFalse);
    expect(paths.any((p) => '$p'.contains('node_modules')), isFalse);
    expect(r['truncated'], isFalse);
    final first = (r['files'] as List).first as Map;
    expect(first['bytes'], isA<int>());
    expect(first['modified'], isA<String>());
  });

  test('artifactsList: subdir + path di luar workspace ditolak', () async {
    final ws = Directory('${temp.path}/workspace');
    Directory('${ws.path}/catatan').createSync();
    File('${ws.path}/catatan/a.txt').writeAsStringSync('a');
    final r = rt.artifactsList(sub: 'catatan');
    expect((r['files'] as List).length, 1);
    expect(((r['files'] as List).first as Map)['path'], 'a.txt');

    expect(() => rt.artifactsList(sub: '../logs'), throwsArgumentError);
    expect(() => rt.artifactsList(sub: '/etc'), throwsArgumentError);
  });

  test('artifactsRead: teks terbaca; biner ditandai; missing 404-ish', () {
    final ws = Directory('${temp.path}/workspace');
    File('${ws.path}/a.txt').writeAsStringSync('isi berkas');
    File('${ws.path}/img.bin')
        .writeAsBytesSync([0x89, 0x50, 0, 0x4E, 0x47, 1, 2, 3]);

    final text = rt.artifactsRead('a.txt');
    expect(text['binary'], isFalse);
    expect(text['content'], 'isi berkas');
    expect(text['truncated'], isFalse);

    final binary = rt.artifactsRead('img.bin');
    expect(binary['binary'], isTrue);
    expect(binary.containsKey('content'), isFalse);

    expect(() => rt.artifactsRead('tidak-ada.txt'), throwsStateError);
    expect(() => rt.artifactsRead('../config.yaml'), throwsArgumentError);
  });

  test('artifactsRead: konten besar terpotong di maxBytes', () {
    final ws = Directory('${temp.path}/workspace');
    File('${ws.path}/big.txt').writeAsStringSync('x' * 400000);
    final r = rt.artifactsRead('big.txt', maxBytes: 1000);
    expect(r['truncated'], isTrue);
    expect((r['content'] as String).length, 1000);
  });

  test('artifactsDiff: LCS marker +/-/= vs .bak dan file baru', () async {
    final ws = Directory('${temp.path}/workspace');
    final f = File('${ws.path}/script.dart');
    f.writeAsStringSync('a\nb\nc\n');
    await f.copy('${ws.path}/script.dart.bak');
    f.writeAsStringSync('a\nb2\nc\nd\n');

    final r = rt.artifactsDiff('script.dart');
    expect(r['old_exists'], isTrue);
    expect(r['new_exists'], isTrue);
    final lines = (r['lines'] as List).map((e) => (e as Map)['type']).join();
    expect(lines.contains('-'), isTrue);
    expect(lines.contains('+'), isTrue);
    final texts = (r['lines'] as List)
        .where((e) => (e as Map)['type'] == '+')
        .map((e) => (e as Map)['text'])
        .toList();
    expect(texts, contains('b2'));
    expect(texts, contains('d'));

    final fresh = rt.artifactsDiff('tanpa-bak.txt');
    expect(fresh['old_exists'], isFalse);
    expect(fresh['lines'], isEmpty);

    expect(
        () => rt.artifactsDiff('../../etc/passwd'), throwsArgumentError);
  });

  test('artifactsDiff: maxEntries membatasi marker', () async {
    final ws = Directory('${temp.path}/workspace');
    final f = File('${ws.path}/big.dart');
    f.writeAsStringSync(List.generate(3000, (i) => 'old $i').join('\n'));
    await f.copy('${ws.path}/big.dart.bak');
    f.writeAsStringSync(List.generate(3000, (i) => 'new $i').join('\n'));
    final r = rt.artifactsDiff('big.dart', maxEntries: 10);
    expect((r['lines'] as List).length, 10);
    expect(r['truncated'], isTrue);
  });
}

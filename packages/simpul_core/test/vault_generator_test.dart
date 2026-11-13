import 'dart:io';

import 'package:simpul_core/simpul_core.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('simpul-gen-test');
  });

  tearDown(() async {
    await tmp.delete(recursive: true);
  });

  test('generates a deterministic vault for the same seed', () async {
    final outA = '${tmp.path}/a';
    final outB = '${tmp.path}/b';
    final manifestA = await VaultGenerator(seed: 7).generate(outA, 40);
    final manifestB = await VaultGenerator(seed: 7).generate(outB, 40);
    expect(manifestA.toJson(), manifestB.toJson());

    String listingOf(String dir) {
      final files = Directory('$dir/catatan_vault').listSync(recursive: true)
          .whereType<File>()
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
      return [
        for (final f in files) f.path.split('/catatan_vault/').last,
      ].join('\n');
    }
    expect(listingOf(outA), listingOf(outB));
  });

  test('manifest counts match the generated vault', () async {
    final manifest = await VaultGenerator(seed: 42).generate(
      '${tmp.path}/v',
      30,
      attachments: 2,
    );
    expect(manifest.noteCount, 30);
    expect(manifest.attachments, 2);
    expect(manifest.linkCount, greaterThan(0));

    final vault = Directory('${tmp.path}/v/catatan_vault');
    final mdFiles = vault
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.md'))
        .length;
    expect(mdFiles, 30);
    expect(File('${tmp.path}/v/.obsidian/app.json').existsSync(), isTrue);
    expect(File('${tmp.path}/v/catatan_vault/lampiran/gambar-0.png').existsSync(), isTrue);
  });

  test('produces broken links and degree concentration', () async {
    final out = '${tmp.path}/v';
    final manifest = await VaultGenerator(seed: 3).generate(out, 120);
    expect(manifest.brokenLinks, greaterThan(0));

    final notes = await VaultScanner.scan('$out/catatan_vault');
    final inDegree = <String, int>{};
    for (final note in notes) {
      for (final link in note.parsed.links) {
        if (link.embed) continue;
        inDegree[link.target] = (inDegree[link.target] ?? 0) + 1;
      }
    }
    final counts = inDegree.values.toList()..sort();
    final median = counts[counts.length ~/ 2];
    expect(counts.last, greaterThan(median * 3));
  });

  test('refuses to overwrite an existing directory', () async {
    await VaultGenerator(seed: 1).generate('${tmp.path}/v', 5);
    expect(
      () => VaultGenerator(seed: 1).generate('${tmp.path}/v', 5),
      throwsArgumentError,
    );
  });
}

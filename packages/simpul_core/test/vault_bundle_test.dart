import 'dart:convert';
import 'dart:io';

import 'package:simpul_core/simpul_core.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  late String vault;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('simpul-bundle-test');
    vault = '${tmp.path}/vault';
    await Directory('$vault/ml').create(recursive: true);
    await File('$vault/ml/a.md')
        .writeAsString('---\ntitle: A\n---\nrahasia A\n');
    await File('$vault/ml/b.md')
        .writeAsString('---\ntitle: B\n---\nrahasia B\n');
    final index = JsonVaultIndex('$vault/.simpul/index.json');
    final notes = await VaultScanner.scan(vault);
    await index.replaceAll(notes.map((n) => n.toIndexed()).toList());
    await index.close();
  });

  tearDown(() async {
    await tmp.delete(recursive: true);
  });

  test('roundtrip export → import menghasilkan byte identik', () async {
    final bag = '${tmp.path}/vault.simpulbag';
    final exported = await VaultBundle.exportBundle(
      vault,
      password: 'sandi-kuat',
      outPath: bag,
    );
    expect(exported.fileCount, 3);
    expect(File(bag).existsSync(), isTrue);
    expect(
      File(bag).readAsBytesSync().sublist(0, 8),
      utf8.encode('SMPLBAG1'),
    );

    final dest = '${tmp.path}/restored';
    final imported = await VaultBundle.importBundle(
      bag,
      password: 'sandi-kuat',
      outDir: dest,
    );
    expect(imported.fileCount, 3);
    expect(
      File('$dest/ml/a.md').readAsStringSync(),
      File('$vault/ml/a.md').readAsStringSync(),
    );
    expect(
      File('$dest/.simpul/index.json').readAsStringSync(),
      File('$vault/.simpul/index.json').readAsStringSync(),
    );
  });

  test('vault terkunci m3 tetap bisa diekspor dengan SIMPUL_PASSWORD',
      () async {
    await VaultModes.lock(vault, password: 'sandi-kuat', mode: 'm3');
    final bag = '${tmp.path}/locked.simpulbag';
    final crypto = await VaultCrypto.open(
      File('$vault/.simpul/vault-key.crate').readAsBytesSync(),
      password: 'sandi-kuat',
    );
    await VaultBundle.exportBundle(
      vault,
      password: 'sandi-kuat',
      outPath: bag,
      crypto: crypto,
    );

    final dest = '${tmp.path}/restored';
    await VaultBundle.importBundle(
      bag,
      password: 'sandi-kuat',
      outDir: dest,
    );
    expect(
      File('$dest/ml/a.md').readAsStringSync(),
      contains('rahasia A'),
    );
  });

  test('password salah ditolak', () async {
    final bag = '${tmp.path}/vault.simpulbag';
    await VaultBundle.exportBundle(
      vault,
      password: 'sandi-benar',
      outPath: bag,
    );
    expect(
      () => VaultBundle.importBundle(
        bag,
        password: 'sandi-salah',
        outDir: '${tmp.path}/restored',
      ),
      throwsA(isA<VaultCryptoException>()),
    );
  });

  test('bundle yang dimanipulasi ditolak AEAD', () async {
    final bag = '${tmp.path}/vault.simpulbag';
    await VaultBundle.exportBundle(
      vault,
      password: 'sandi-kuat',
      outPath: bag,
    );
    final bytes = File(bag).readAsBytesSync();
    bytes[bytes.length - 3] ^= 0x01;
    await File(bag).writeAsBytes(bytes);
    expect(
      () => VaultBundle.importBundle(
        bag,
        password: 'sandi-kuat',
        outDir: '${tmp.path}/restored',
      ),
      throwsA(isA<VaultCryptoException>()),
    );
  });

  test('bukan bundle dan versi asing ditolak', () async {
    final plain = '${tmp.path}/plain.bin';
    await File(plain).writeAsBytes([1, 2, 3]);
    expect(
      () => VaultBundle.importBundle(
        plain,
        password: 'x',
        outDir: '${tmp.path}/r1',
      ),
      throwsA(isA<VaultBundleException>()),
    );
    final bag = '${tmp.path}/vault.simpulbag';
    await VaultBundle.exportBundle(
      vault,
      password: 'sandi-kuat',
      outPath: bag,
    );
    final bytes = File(bag).readAsBytesSync();
    bytes[8] = 99;
    final foreign = '${tmp.path}/foreign.simpulbag';
    await File(foreign).writeAsBytes(bytes);
    expect(
      () => VaultBundle.importBundle(
        foreign,
        password: 'sandi-kuat',
        outDir: '${tmp.path}/r2',
      ),
      throwsA(isA<VaultBundleException>()),
    );
  });

  test('vault kosong ditolak, vault tak ada ditolak', () async {
    final empty = '${tmp.path}/empty-vault';
    await Directory(empty).create();
    expect(
      () => VaultBundle.exportBundle(
        empty,
        password: 'x',
        outPath: '${tmp.path}/empty.simpulbag',
      ),
      throwsA(isA<VaultBundleException>()),
    );
    expect(
      () => VaultBundle.exportBundle(
        '${tmp.path}/tidak-ada',
        password: 'x',
        outPath: '${tmp.path}/none.simpulbag',
      ),
      throwsA(isA<VaultBundleException>()),
    );
  });
}

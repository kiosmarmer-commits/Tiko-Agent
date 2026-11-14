import 'dart:io';

import 'package:simpul_core/simpul_core.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  late String vault;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('simpul-modes-test');
    vault = '${tmp.path}/vault';
    await Directory('$vault/publik').create(recursive: true);
    await Directory('$vault/rahasia').create(recursive: true);
    await File('$vault/publik/terbuka.md').writeAsString(
      '---\ntitle: Terbuka\n---\n# Terbuka\n\nisi publik untuk semua\n',
    );
    await File('$vault/rahasia/kunci.md').writeAsString(
      '---\ntitle: Kunci\n---\nrahasia bank dan sandi\n',
    );
    await Directory('$vault/.obsidian').create();
    await File('$vault/.obsidian/config.md').writeAsString('config\n');
  });

  tearDown(() async {
    await tmp.delete(recursive: true);
  });

  test('lock M1 encrypts index artifacts only, notes stay plain', () async {
    final result = await VaultModes.lock(vault, password: 'sandi-kuat');

    expect(result.mode, 'm1');
    expect(result.folders, isEmpty);
    expect(VaultModes.isLocked(vault), isTrue);
    expect(VaultCrypto.isFileEncrypted('$vault/.simpul/index.json'), isFalse);
    expect(VaultCrypto.isFileEncrypted('$vault/publik/terbuka.md'), isFalse);

    final status = await VaultModes.status(vault);
    expect(status.mode, 'm1');
    expect(status.locked, isTrue);
    expect(status.encryptedNotes, 0);
    expect(status.totalNotes, 2);
  });

  test('lock M2 encrypts only the selected folders', () async {
    final result = await VaultModes.lock(
      vault,
      password: 'sandi-kuat',
      mode: 'm2',
      folders: ['rahasia'],
    );

    expect(result.mode, 'm2');
    expect(result.folders, ['rahasia']);
    expect(VaultCrypto.isFileEncrypted('$vault/rahasia/kunci.md'), isTrue);
    expect(VaultCrypto.isFileEncrypted('$vault/publik/terbuka.md'), isFalse);
    expect(VaultCrypto.isFileEncrypted('$vault/.obsidian/config.md'), isFalse);

    final status = await VaultModes.status(vault);
    expect(status.mode, 'm2');
    expect(status.folders, ['rahasia']);
    expect(status.encryptedNotes, 1);
    expect(status.totalNotes, 2);
  });

  test('lock M3 encrypts every note in the vault', () async {
    final result = await VaultModes.lock(vault, password: 'sandi-kuat', mode: 'm3');

    expect(result.mode, 'm3');
    expect(VaultCrypto.isFileEncrypted('$vault/publik/terbuka.md'), isTrue);
    expect(VaultCrypto.isFileEncrypted('$vault/rahasia/kunci.md'), isTrue);
    expect(VaultCrypto.isFileEncrypted('$vault/.obsidian/config.md'), isFalse);

    final status = await VaultModes.status(vault);
    expect(status.encryptedNotes, 2);
  });

  test('scan decrypts encrypted notes with the key and fails closed without',
      () async {
    await VaultModes.lock(vault, password: 'sandi-kuat', mode: 'm3');
    final crypto = await VaultCrypto.open(
      File('$vault/.simpul/vault-key.crate').readAsBytesSync(),
      password: 'sandi-kuat',
    );

    final notes = await VaultScanner.scan(vault, crypto: crypto);
    expect(notes.length, 2);
    final kunci = notes.singleWhere((n) => n.path == 'rahasia/kunci.md');
    expect(kunci.parsed.title, 'Kunci');
    expect(kunci.parsed.chunks.single.text, contains('rahasia bank'));

    await expectLater(
      VaultScanner.scan(vault),
      throwsA(isA<VaultCryptoException>()),
    );
  });

  test('content hash is stable between plaintext and encrypted scans', () async {
    final plainNotes = await VaultScanner.scan(vault);
    final plainHash =
        plainNotes.singleWhere((n) => n.path == 'rahasia/kunci.md').contentHash;

    await VaultModes.lock(vault, password: 'sandi-kuat', mode: 'm3');
    final crypto = await VaultCrypto.open(
      File('$vault/.simpul/vault-key.crate').readAsBytesSync(),
      password: 'sandi-kuat',
    );
    final lockedNotes = await VaultScanner.scan(vault, crypto: crypto);
    final lockedHash =
        lockedNotes.singleWhere((n) => n.path == 'rahasia/kunci.md').contentHash;

    expect(lockedHash, plainHash);
  });

  test('unlock restores every encrypted note byte-for-byte', () async {
    final before = await File('$vault/rahasia/kunci.md').readAsBytes();
    await VaultModes.lock(vault, password: 'sandi-kuat', mode: 'm3');
    final result = await VaultModes.unlock(vault, password: 'sandi-kuat');

    expect(result.decrypted, containsAll(['rahasia/kunci.md', 'publik/terbuka.md']));
    expect(VaultModes.isLocked(vault), isFalse);
    expect(File('$vault/.simpul/vault-key.crate').existsSync(), isFalse);
    expect(await File('$vault/rahasia/kunci.md').readAsBytes(), before);

    final status = await VaultModes.status(vault);
    expect(status.mode, 'm0');
    expect(status.locked, isFalse);
    expect(status.encryptedNotes, 0);
  });

  test('unlock with the wrong password fails closed', () async {
    await VaultModes.lock(vault, password: 'sandi-kuat', mode: 'm3');
    await expectLater(
      VaultModes.unlock(vault, password: 'sandi-salah'),
      throwsA(isA<VaultCryptoException>()),
    );
    expect(VaultModes.isLocked(vault), isTrue);
  });

  test('lock/unlock argument and state errors', () async {
    await expectLater(
      VaultModes.lock(vault, password: 's', mode: 'm4'),
      throwsArgumentError,
    );
    await expectLater(
      VaultModes.lock(vault, password: 's', mode: 'm2'),
      throwsArgumentError,
    );
    await expectLater(
      VaultModes.lock(vault, password: 's', mode: 'm2', folders: ['tidak-ada']),
      throwsStateError,
    );
    await expectLater(
      VaultModes.unlock(vault, password: 's'),
      throwsStateError,
    );
    await VaultModes.lock(vault, password: 'sandi-kuat');
    await expectLater(
      VaultModes.lock(vault, password: 'sandi-kuat'),
      throwsStateError,
    );
  });
}

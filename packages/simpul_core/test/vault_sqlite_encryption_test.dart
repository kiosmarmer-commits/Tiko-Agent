import 'dart:io';

import 'package:simpul_core/simpul_core.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  late String vault;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('simpul-sqlite-enc-test');
    vault = '${tmp.path}/vault';
    await Directory(vault).create(recursive: true);
    await File('$vault/catatan.md').writeAsString(
      '---\ntitle: Catatan\n---\nisi catatan rahasia\n',
    );
  });

  tearDown(() async {
    await tmp.delete(recursive: true);
  });

  test('backend sqlite nyata tersedia di lingkungan ini', () {
    final index = SqliteVaultIndex.tryOpen(
      '${tmp.path}/probe.db',
    );
    if (index == null) {
      markTestSkipped('libsqlite3 tidak tersedia di lingkungan ini');
      return;
    }
    index.close();
  });

  test('isFileEncrypted membedakan db polos dan db SQLCipher', () async {
    final dbPath = '${tmp.path}/plain.db';
    final index = SqliteVaultIndex.tryOpen(dbPath);
    if (index == null) {
      markTestSkipped('libsqlite3 tidak tersedia di lingkungan ini');
      return;
    }
    await index.replaceAll(const []);
    await index.close();
    expect(SqliteVaultIndex.isFileEncrypted(dbPath), isFalse);

    if (!SqliteVaultIndex.sqlcipherAvailable) {
      markTestSkipped('libsqlcipher tidak tersedia di lingkungan ini');
      return;
    }
    final key = List<int>.generate(32, (i) => i + 1);
    expect(SqliteVaultIndex.encryptFileInPlace(dbPath, key), isTrue);
    expect(SqliteVaultIndex.isFileEncrypted(dbPath), isTrue);
  });

  test('roundtrip sqlite terenkripsi: buka dengan kunci, kunci salah gagal',
      () async {
    if (!SqliteVaultIndex.sqlcipherAvailable) {
      markTestSkipped('libsqlcipher tidak tersedia di lingkungan ini');
      return;
    }
    final dbPath = '${tmp.path}/enc.db';
    final key = List<int>.generate(32, (i) => (i * 7) & 0xFF);
    final index = SqliteVaultIndex.tryOpen(dbPath, vaultKey: key);
    expect(index, isNotNull);
    final notes = await VaultScanner.scan(vault);
    await index!.replaceAll(notes.map((n) => n.toIndexed()).toList());
    await index.close();

    final reopened = SqliteVaultIndex.tryOpen(dbPath, vaultKey: key);
    expect(reopened, isNotNull);
    final note = await reopened!.noteByPath('catatan.md');
    expect(note, isNotNull);
    expect(note!.title, 'Catatan');
    await reopened.close();

    final wrongKey = List<int>.of(key)..[0] ^= 0xff;
    expect(
      () => SqliteVaultIndex.tryOpen(dbPath, vaultKey: wrongKey),
      throwsA(isA<VaultCryptoException>()),
    );
  });

  test('VaultModes lock/unlock mengenkripsi index.db end-to-end', () async {
    final dbPath = '$vault/.simpul/index.db';
    final index = SqliteVaultIndex.tryOpen(dbPath);
    if (index == null) {
      markTestSkipped('libsqlite3 tidak tersedia di lingkungan ini');
      return;
    }
    final notes = await VaultScanner.scan(vault);
    await index.replaceAll(notes.map((n) => n.toIndexed()).toList());
    await index.close();

    if (!SqliteVaultIndex.sqlcipherAvailable) {
      markTestSkipped('libsqlcipher tidak tersedia di lingkungan ini');
      return;
    }

    final locked = await VaultModes.lock(vault, password: 'sandi', mode: 'm3');
    expect(locked.encrypted, contains('index.db'));
    expect(SqliteVaultIndex.isFileEncrypted(dbPath), isTrue);
    final status = await VaultModes.status(vault);
    expect(status.locked, isTrue);
    expect(status.indexFiles['index.db'], isTrue);

    final unlocked = await VaultModes.unlock(vault, password: 'sandi');
    expect(unlocked.decrypted, contains('index.db'));
    expect(SqliteVaultIndex.isFileEncrypted(dbPath), isFalse);
    expect(VaultModes.isLocked(vault), isFalse);
  });
}

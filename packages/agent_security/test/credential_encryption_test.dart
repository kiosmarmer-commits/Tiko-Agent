import 'dart:io';

import 'package:agent_security/agent_security.dart';
import 'package:test/test.dart';

void main() {
  late Directory dir;
  late String storagePath;
  const passphrase = 'uji-passphrase-aman';

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('cred_enc_test');
    storagePath = '${dir.path}${Platform.pathSeparator}credentials.json';
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  test('dengan passphrase: file tersegel TSS2, roundtrip berhasil', () async {
    final mgr = CredentialManager(
      storagePath: storagePath,
      passphrase: passphrase,
    );
    await mgr.initialize();
    await mgr.addCredential(provider: 'openai', key: 'sk-rahasia');

    final bytes = await File(storagePath).readAsBytes();
    expect(String.fromCharCodes(bytes.sublist(0, 4)), 'TSS2');
    expect(String.fromCharCodes(bytes).contains('sk-rahasia'), isFalse);

    final fresh = CredentialManager(
      storagePath: storagePath,
      passphrase: passphrase,
    );
    await fresh.initialize();
    final entry = await fresh.getCredential(provider: 'openai');
    expect(entry, isNotNull);
    expect(entry!.key, 'sk-rahasia');
  });

  test('migrasi: plaintext lama disegel saat initialize dengan passphrase',
      () async {
    await File(storagePath).writeAsString(
      '{"openai":[{"id":"aabbccdd","provider":"openai","key":"sk-lama",'
      '"name":"lama","metadata":{},"createdAt":"2026-11-15T00:00:00.000Z",'
      '"lastUsed":null,"usageCount":0,"failures":0}]}',
    );
    final mgr = CredentialManager(
      storagePath: storagePath,
      passphrase: passphrase,
    );
    await mgr.initialize();

    final bytes = await File(storagePath).readAsBytes();
    expect(String.fromCharCodes(bytes.sublist(0, 4)), 'TSS2');
    final entry = await mgr.getCredential(provider: 'openai');
    expect(entry, isNotNull);
    expect(entry!.key, 'sk-lama');
  });

  test('passphrase salah: initialize gagal keras', () async {
    final mgr = CredentialManager(
      storagePath: storagePath,
      passphrase: passphrase,
    );
    await mgr.initialize();
    await mgr.addCredential(provider: 'openai', key: 'sk-rahasia');

    final wrong = CredentialManager(
      storagePath: storagePath,
      passphrase: 'passphrase-salah',
    );
    await expectLater(wrong.initialize(), throwsA(anything));
  });

  test('file tersegel tanpa passphrase: error jelas, bukan korup', () async {
    final mgr = CredentialManager(
      storagePath: storagePath,
      passphrase: passphrase,
    );
    await mgr.initialize();
    await mgr.addCredential(provider: 'openai', key: 'sk-rahasia');

    final noPass = CredentialManager(storagePath: storagePath);
    await expectLater(noPass.initialize(), throwsA(isA<StateError>()));
  });

  test('migrasi gagal (dir read-only): plaintext lama tetap utuh', () async {
    const plaintext = '{"openai":[{"id":"aabbccdd","provider":"openai",'
        '"key":"sk-lama","name":"lama","metadata":{},'
        '"createdAt":"2026-11-15T00:00:00.000Z","lastUsed":null,'
        '"usageCount":0,"failures":0}]}';
    await File(storagePath).writeAsString(plaintext);

    await Process.run('chmod', ['500', dir.path]);
    final mgr = CredentialManager(
      storagePath: storagePath,
      passphrase: passphrase,
    );
    try {
      await expectLater(mgr.initialize(), throwsA(anything));

      final raw = await File(storagePath).readAsString();
      expect(raw, plaintext);
    } finally {
      await Process.run('chmod', ['700', dir.path]);
    }
  });

  test('simpan sukses tidak meninggalkan file .tmp', () async {
    final mgr = CredentialManager(
      storagePath: storagePath,
      passphrase: passphrase,
    );
    await mgr.initialize();
    await mgr.addCredential(provider: 'openai', key: 'sk-rahasia');
    await mgr.addCredential(provider: 'anthropic', key: 'ak-lain');

    final leftovers = dir
        .listSync()
        .map((e) => e.path)
        .where((path) => path.endsWith('.tmp'))
        .toList();
    expect(leftovers, isEmpty);

    final fresh = CredentialManager(
      storagePath: storagePath,
      passphrase: passphrase,
    );
    await fresh.initialize();
    expect((await fresh.getCredential(provider: 'openai'))!.key, 'sk-rahasia');
    expect((await fresh.getCredential(provider: 'anthropic'))!.key, 'ak-lain');
  });
}

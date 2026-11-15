import 'dart:io';

import 'package:agent_security/agent_security.dart';
import 'package:test/test.dart';

void main() {
  late Directory dir;
  late String storagePath;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('cred_mgr_test');
    storagePath =
        '${dir.path}${Platform.pathSeparator}credentials.json';
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  test('addCredential tersimpan dan bisa dibaca ulang', () async {
    final mgr = CredentialManager(storagePath: storagePath);
    await mgr.initialize();
    await mgr.addCredential(provider: 'openai', key: 'sk-abc');
    final fresh = CredentialManager(storagePath: storagePath);
    await fresh.initialize();
    final entry = await fresh.getCredential(provider: 'openai');
    expect(entry, isNotNull);
    expect(entry!.key, 'sk-abc');
  });

  test('file kredensial 600 di POSIX', () async {
    final mgr = CredentialManager(storagePath: storagePath);
    await mgr.initialize();
    await mgr.addCredential(provider: 'openai', key: 'sk-abc');
    if (!Platform.isWindows) {
      final stat = await File(storagePath).stat();
      expect(stat.mode & 511, 384); // 0600
    }
  });

  test('permission longgar diperketat saat initialize', () async {
    await File(storagePath).writeAsString('{"openai":[]}');
    if (!Platform.isWindows) {
      await Process.run('chmod', ['644', storagePath]);
      final mgr = CredentialManager(storagePath: storagePath);
      await mgr.initialize();
      final stat = await File(storagePath).stat();
      expect(stat.mode & 511, 384); // 0600
    }
  });

  test('kegagalan simpan tidak ditelan', () async {
    final mgr = CredentialManager(
      storagePath: '${dir.path}/tidak_ada/secrets/credentials.json',
    );
    await mgr.initialize();
    await expectLater(
      mgr.addCredential(provider: 'openai', key: 'sk-abc'),
      completes,
    );
    final broken = CredentialManager(storagePath: '/proc/forbidden/cred.json');
    await broken.initialize();
    await expectLater(
      broken.addCredential(provider: 'openai', key: 'sk-abc'),
      throwsA(anything),
    );
  });

  test('ID kredensial CSPRNG: unik dan hex 32 char', () async {
    final mgr = CredentialManager(storagePath: storagePath);
    await mgr.initialize();
    await mgr.addCredential(provider: 'openai', key: 'sk-1');
    await mgr.addCredential(provider: 'openai', key: 'sk-2');
    final a = await mgr.getCredential(provider: 'openai');
    final b = await mgr.getCredential(provider: 'openai');
    expect(a!.id, isNot(equals(b!.id)));
    expect(RegExp(r'^[0-9a-f]{32}
).hasMatch(a.id), isTrue);
  });

  test('enkripsi at-rest: payload disegel TSS2 tanpa plaintext', () async {
    final mgr = CredentialManager(
      storagePath: storagePath,
      passphrase: 'passphrase-tes',
    );
    await mgr.initialize();
    await mgr.addCredential(provider: 'openai', key: 'sk-rahasia');
    final raw = await File(storagePath).readAsBytes();
    expect(raw[0], 0x54); // 'T'
    expect(raw[1], 0x53); // 'S'
    expect(raw[2], 0x53); // 'S'
    expect(raw[3], 0x32); // '2'
    expect(String.fromCharCodes(raw), isNot(contains('sk-rahasia')));

    final fresh = CredentialManager(
      storagePath: storagePath,
      passphrase: 'passphrase-tes',
    );
    await fresh.initialize();
    final entry = await fresh.getCredential(provider: 'openai');
    expect(entry, isNotNull);
    expect(entry!.key, 'sk-rahasia');
  });

  test('file terenkripsi tanpa passphrase ditolak saat initialize', () async {
    final mgr = CredentialManager(
      storagePath: storagePath,
      passphrase: 'passphrase-tes',
    );
    await mgr.initialize();
    await mgr.addCredential(provider: 'openai', key: 'sk-rahasia');
    final locked = CredentialManager(storagePath: storagePath);
    await expectLater(locked.initialize(), throwsA(isA<StateError>()));
  });

  test('plaintext legacy dimigrasi ke terenkripsi saat passphrase diset',
      () async {
    await File(storagePath).writeAsString(
      '{"openai":[{"id":"abc","provider":"openai","key":"sk-lama",'
      '"name":"k1","metadata":{},"createdAt":"2026-11-15T00:00:00.000Z",'
      '"lastUsed":null,"usageCount":0,"failures":0}]}',
    );
    final mgr = CredentialManager(
      storagePath: storagePath,
      passphrase: 'passphrase-tes',
    );
    await mgr.initialize();
    final raw = await File(storagePath).readAsBytes();
    expect(String.fromCharCodes(raw).startsWith('TSS2'), isTrue);
    expect(String.fromCharCodes(raw), isNot(contains('sk-lama')));
    final entry = await mgr.getCredential(provider: 'openai');
    expect(entry, isNotNull);
    expect(entry!.key, 'sk-lama');
  });
}

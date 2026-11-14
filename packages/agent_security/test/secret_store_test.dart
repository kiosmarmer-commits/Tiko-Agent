import 'dart:convert';
import 'dart:io';

import 'package:agent_security/agent_security.dart';
import 'package:test/test.dart';

void main() {
  late Directory dir;
  late String path;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('secret_store_test');
    path = '${dir.path}${Platform.pathSeparator}secrets.bin';
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  test('roundtrip write/read', () async {
    final store = SecretStore(path: path, passphrase: 'frasa-rahasia');
    await store.write('openai', 'sk-test-123');
    await store.write('anthropic', 'key-456');
    expect(await store.read('openai'), 'sk-test-123');
    expect(await store.read('anthropic'), 'key-456');
    expect(await store.read('tidak_ada'), isNull);
  });

  test('file tidak menyimpan plaintext', () async {
    final store = SecretStore(path: path, passphrase: 'frasa-rahasia');
    await store.write('openai', 'sk-plaintext-visible');
    final raw = await File(path).readAsBytes();
    expect(utf8.decode(raw, allowMalformed: true),
        isNot(contains('sk-plaintext-visible')));
    expect(utf8.decode(raw.sublist(0, 4)), 'TSS2');
  });

  test('salt unik per write: ciphertext berubah untuk data sama', () async {
    final store = SecretStore(path: path, passphrase: 'frasa-rahasia');
    await store.write('k', 'v');
    final first = await File(path).readAsBytes();
    await store.write('k', 'v');
    final second = await File(path).readAsBytes();
    expect(first, isNot(equals(second)));
  });

  test('tamper MAC dilempar sebagai SecretStoreException', () async {
    final store = SecretStore(path: path, passphrase: 'frasa-rahasia');
    await store.write('k', 'v');
    final raw = await File(path).readAsBytes();
    raw[raw.length - 1] ^= 0xFF;
    await File(path).writeAsBytes(raw);
    await expectLater(
      store.read('k'),
      throwsA(isA<SecretStoreException>()),
    );
  });

  test('passphrase salah ditolak', () async {
    final store = SecretStore(path: path, passphrase: 'benar');
    await store.write('k', 'v');
    final wrong = SecretStore(path: path, passphrase: 'salah');
    await expectLater(wrong.read('k'), throwsA(isA<SecretStoreException>()));
  });

  test('permission file 600 di POSIX', () async {
    final store = SecretStore(path: path, passphrase: 'frasa-rahasia');
    await store.write('k', 'v');
    if (!Platform.isWindows) {
      final stat = await File(path).stat();
      expect(stat.mode & 511, 384); // 0777 / 0600
    }
  });

  test('migrasi format legacy XOR ke v2', () async {
    final legacy = _legacyEncode(
      passphrase: 'frasa-rahasia',
      data: {'openai': 'sk-lama'},
    );
    await File(path).writeAsString(legacy);
    final store = SecretStore(path: path, passphrase: 'frasa-rahasia');
    expect(await store.read('openai'), 'sk-lama');
    final raw = await File(path).readAsBytes();
    expect(utf8.decode(raw.sublist(0, 4)), 'TSS2');
    expect(await store.read('openai'), 'sk-lama');
  });

  test('file hilang berarti map kosong', () async {
    final store = SecretStore(path: path, passphrase: 'frasa-rahasia');
    expect(await store.read('k'), isNull);
  });
}

String _legacyEncode({
  required String passphrase,
  required Map<String, String> data,
}) {
  final salt = List<int>.generate(16, (i) => i + 1);
  final payload = utf8.encode(jsonEncode(data));
  final seed = utf8.encode(passphrase) + salt;
  var state = 0;
  for (final b in seed) {
    state = (state * 31 + b) & 0x7fffffff;
  }
  final ks = List<int>.generate(payload.length, (_) {
    state = (state * 1103515245 + 12345) & 0x7fffffff;
    return (state >> 16) & 0xff;
  });
  final enc = List<int>.generate(
    payload.length,
    (i) => payload[i] ^ ks[i],
  );
  return base64Encode([...salt, ...enc]);
}

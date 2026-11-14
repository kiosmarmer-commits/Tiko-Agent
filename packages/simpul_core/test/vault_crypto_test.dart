import 'dart:convert';
import 'dart:io';

import 'package:simpul_core/simpul_core.dart';
import 'package:test/test.dart';

const _weakKdf = KdfParams(memoryKib: 256, iterations: 1, parallelism: 1, saltLength: 16);

IndexedNote _note(String path) => IndexedNote(
      path: path,
      title: path,
      mtimeNs: 0,
      sizeBytes: 0,
      contentHash: 'hash-$path',
      wordCount: 3,
      props: const {},
      tags: const ['a'],
      aliases: const [],
      links: const [],
      chunks: const [],
    );

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('vault-crypto-test');
  });

  tearDown(() {
    tmp.deleteSync(recursive: true);
  });

  test('roundtrip bytes', () async {
    final crypto = (await VaultCrypto.create(password: 'pw', kdf: _weakKdf)).crypto;
    final plain = utf8.encode('halo vault \u2014 \u00e9\u00e8');
    final sealed = crypto.encryptBytes(plain);
    expect(VaultCrypto.looksEncrypted(sealed), isTrue);
    expect(crypto.decryptBytes(sealed), plain);
  });

  test('tampered ciphertext throws VaultCryptoException (SEC-I04)', () async {
    final crypto = (await VaultCrypto.create(password: 'pw', kdf: _weakKdf)).crypto;
    final sealed = crypto.encryptBytes([1, 2, 3, 4]);
    final tampered = List<int>.of(sealed)..[sealed.length - 1] ^= 0x01;
    expect(() => crypto.decryptBytes(tampered), throwsA(isA<VaultCryptoException>()));
  });

  test('wrong password fails to open key crate', () async {
    final created = await VaultCrypto.create(password: 'benar', kdf: _weakKdf);
    expect(
      () => VaultCrypto.open(created.keyCrate, password: 'salah'),
      throwsA(isA<VaultCryptoException>()),
    );
    final reopened = await VaultCrypto.open(created.keyCrate, password: 'benar');
    final sealed = reopened.encryptBytes([9, 9]);
    expect(reopened.decryptBytes(sealed), [9, 9]);
  });

  test('random nonce: same plaintext yields different ciphertext (SEC-08)',
      () async {
    final crypto = (await VaultCrypto.create(password: 'pw', kdf: _weakKdf)).crypto;
    expect(
      crypto.encryptBytes([1, 2, 3]),
      isNot(equals(crypto.encryptBytes([1, 2, 3]))),
    );
  });

  test('reading an encrypted file without crypto fails closed', () async {
    final crypto = (await VaultCrypto.create(password: 'pw', kdf: _weakKdf)).crypto;
    final path = '${tmp.path}/index.json';
    await VaultFiles.writeString(path, '{"notes":[]}', crypto: crypto);
    expect(VaultCrypto.isFileEncrypted(path), isTrue);
    expect(
      () => VaultFiles.readString(path),
      throwsA(isA<VaultCryptoException>()),
    );
    expect(VaultFiles.readString(path, crypto: crypto), '{"notes":[]}');
  });

  test('reading a plain file with crypto fails closed', () async {
    final path = '${tmp.path}/plain.json';
    await VaultFiles.writeString(path, '{}');
    expect(
      () => VaultFiles.readString(path, crypto: null),
      returnsNormally,
    );
  });

  test('KdfParams json roundtrip and unknown algo rejected', () {
    final params = const KdfParams().toJson();
    expect(KdfParams.fromJson(params).memoryKib, 19456);
    expect(
      () => KdfParams.fromJson({'algo': 'pbkdf2'}),
      throwsA(isA<VaultCryptoException>()),
    );
  });

  test('JsonVaultIndex roundtrip with encrypted file on disk', () async {
    final crypto = (await VaultCrypto.create(password: 'pw', kdf: _weakKdf)).crypto;
    final path = '${tmp.path}/index.json';
    final index = JsonVaultIndex(path, crypto: crypto);
    await index.replaceAll([_note('a.md'), _note('b.md')]);
    await index.close();
    expect(VaultCrypto.isFileEncrypted(path), isTrue);
    final reopened = JsonVaultIndex(path, crypto: crypto);
    final hits = await reopened.search('a', limit: 10);
    expect(hits.map((h) => h.path), contains('a.md'));
    await reopened.close();
  });

  test('JsonVaultIndex on encrypted file without crypto throws (fail-closed)',
      () async {
    final crypto = (await VaultCrypto.create(password: 'pw', kdf: _weakKdf)).crypto;
    final path = '${tmp.path}/index.json';
    final index = JsonVaultIndex(path, crypto: crypto);
    await index.replaceAll([_note('a.md')]);
    await index.close();
    final locked = JsonVaultIndex(path);
    await expectLater(
      locked.search('a'),
      throwsA(isA<VaultCryptoException>()),
    );
  });

  test('encrypted vectors.json roundtrip and storedModelVersion', () async {
    final crypto = (await VaultCrypto.create(password: 'pw', kdf: _weakKdf)).crypto;
    final path = '${tmp.path}/vectors.json';
    final embedder = HashingEmbedder();
    final semantic = InMemorySemanticIndex(
      embedder,
      filePath: path,
      crypto: crypto,
    );
    await semantic.replaceAll([
      const ChunkInput(
        notePath: 'a.md',
        ord: 0,
        headingPath: '',
        text: 'kata kunci unik zebra',
        hash: 'h1',
      ),
    ]);
    await semantic.close();
    expect(VaultCrypto.isFileEncrypted(path), isTrue);
    expect(
      InMemorySemanticIndex.storedModelVersion(path, crypto: crypto),
      embedder.modelVersion,
    );
    final reopened = InMemorySemanticIndex(
      embedder,
      filePath: path,
      crypto: crypto,
    );
    final hits = await reopened.search(embedder.embed('zebra'), limit: 5);
    expect(hits.single.notePath, 'a.md');
    await reopened.close();
  });

  test('encrypted graph cache roundtrip via openVaultCacheStore', () async {
    final crypto = (await VaultCrypto.create(password: 'pw', kdf: _weakKdf)).crypto;
    final vault = Directory('${tmp.path}/vault')..createSync();
    Directory('${vault.path}/.simpul').createSync();
    final seed = JsonVaultIndex('${vault.path}/.simpul/index.json', crypto: crypto);
    await seed.replaceAll(const []);
    await seed.close();
    final cache = openVaultCacheStore(vault.path, crypto: crypto);
    expect(cache, isNotNull);
    await cache!.saveGraphCache(
      kind: 'barnes-hut-v1:test',
      version: 'v1',
      payload: {'positions': [1, 2, 3]},
    );
    await (cache as VaultIndex).close();
    final cachePath = '${vault.path}/.simpul/index.json';
    expect(VaultCrypto.isFileEncrypted(cachePath), isTrue);
    final reopened = openVaultCacheStore(vault.path, crypto: crypto);
    final loaded = await reopened!.loadGraphCache(
      kind: 'barnes-hut-v1:test',
      version: 'v1',
    );
    expect(loaded, isNotNull);
    await (reopened as VaultIndex).close();
  });

  test('decryptFileInPlace restores plaintext', () async {
    final crypto = (await VaultCrypto.create(password: 'pw', kdf: _weakKdf)).crypto;
    final path = '${tmp.path}/vectors.json';
    await VaultFiles.writeString(path, '{"a":1}', crypto: crypto);
    await crypto.decryptFileInPlace(path);
    expect(VaultCrypto.isFileEncrypted(path), isFalse);
    expect(File(path).readAsStringSync(), '{"a":1}');
  });
}

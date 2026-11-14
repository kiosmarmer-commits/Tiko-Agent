import 'dart:convert';
import 'dart:io';

import 'package:simpul_core/simpul_core.dart';
import 'package:test/test.dart';

void main() {
  group('VaultRecovery (SEC-06 Shamir)', () {
    const key = [
      0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef, //
      0xfe, 0xdc, 0xba, 0x98, 0x76, 0x54, 0x32, 0x10,
      0x0f, 0x1e, 0x2d, 0x3c, 0x4b, 0x5a, 0x69, 0x78,
      0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff,
    ];

    test('k-of-n: setiap subset threshold merekonstruksi kunci', () {
      final shares = VaultRecovery.splitKey(
        key,
        shares: 5,
        threshold: 3,
      );
      expect(shares.length, 5);
      for (final subset in [
        [shares[0], shares[2], shares[4]],
        [shares[1], shares[2], shares[3]],
        [shares[0], shares[1], shares[2], shares[3], shares[4]],
      ]) {
        expect(VaultRecovery.combineKey(subset), key);
      }
    });

    test('share kurang dari threshold tidak menghasilkan kunci', () {
      final shares = VaultRecovery.splitKey(key, shares: 4, threshold: 3);
      expect(
        () => VaultRecovery.combineKey(shares.sublist(0, 2)),
        throwsA(isA<VaultRecoveryException>()),
      );
    });

    test('share yang dimanipulasi ditolak checksum', () {
      final shares = VaultRecovery.splitKey(key, shares: 3, threshold: 2);
      final bytes = base64Url.decode(shares[1]);
      bytes[bytes.length - 1] ^= 0x01;
      final tampered = base64Url.encode(bytes);
      expect(
        () => VaultRecovery.combineKey([shares[0], tampered]),
        throwsA(isA<VaultRecoveryException>()),
      );
    });

    test('share dari kunci berbeda ditolak', () {
      final other = List<int>.of(key)..[0] ^= 0xff;
      final a = VaultRecovery.splitKey(key, shares: 3, threshold: 2);
      final b = VaultRecovery.splitKey(other, shares: 3, threshold: 2);
      expect(
        () => VaultRecovery.combineKey([a[0], a[1], b[2]]),
        throwsA(isA<VaultRecoveryException>()),
      );
    });

    test('share duplikat ditolak', () {
      final shares = VaultRecovery.splitKey(key, shares: 3, threshold: 2);
      expect(
        () => VaultRecovery.combineKey([shares[0], shares[0]]),
        throwsA(isA<VaultRecoveryException>()),
      );
    });

    test('parameter tidak valid ditolak', () {
      expect(
        () => VaultRecovery.splitKey(key, shares: 3, threshold: 5),
        throwsArgumentError,
      );
      expect(
        () => VaultRecovery.splitKey(key, shares: 3, threshold: 1),
        throwsArgumentError,
      );
      expect(() => VaultRecovery.splitKey(const [], shares: 3, threshold: 2),
          throwsArgumentError);
    });

    test('aritmetika GF(2^8): gfDiv(gfMul(a,b),b) == a', () {
      for (final a in [1, 2, 3, 7, 128, 200, 255]) {
        for (final b in [1, 2, 3, 5, 137, 255]) {
          expect(gfDiv(gfMul(a, b), b), a, reason: '$a/$b');
        }
      }
      expect(gfMul(0, 200), 0);
      expect(gfMul(200, 0), 0);
      expect(() => gfDiv(1, 0), throwsArgumentError);
    });
  });

  group('VaultCrypto wipe (SEC-16)', () {
    test('setelah wipe, enkripsi/dekripsi/ekspor kunci gagal tertutup', () async {
      final created = await VaultCrypto.create(password: 'sandi');
      final crypto = created.crypto;
      final encrypted = crypto.encryptBytes('rahasia'.codeUnits);
      expect(crypto.isWiped, isFalse);
      crypto.wipe();
      expect(crypto.isWiped, isTrue);
      expect(
        () => crypto.encryptBytes('lagi'.codeUnits),
        throwsA(isA<VaultCryptoException>()),
      );
      expect(
        () => crypto.decryptBytes(encrypted),
        throwsA(isA<VaultCryptoException>()),
      );
      expect(
        () => crypto.vaultKeyBytes(),
        throwsA(isA<VaultCryptoException>()),
      );
    });

    test('withVaultKey mendekripsi crate tanpa password', () async {
      final created = await VaultCrypto.create(password: 'sandi');
      final encrypted = created.crypto.encryptBytes('isi vault'.codeUnits);
      final recovered = VaultCrypto.withVaultKey(
        created.crypto.vaultKeyBytes(),
        kdf: created.crypto.kdf,
      );
      expect(recovered.decryptBytes(encrypted), 'isi vault'.codeUnits);
      final crate = await created.crypto.sealKeyCrate('sandi-baru');
      final reopened =
          await VaultCrypto.open(crate, password: 'sandi-baru');
      expect(reopened.decryptBytes(encrypted), 'isi vault'.codeUnits);
    });
  });

  group('VaultAutoLock (SEC-16)', () {
    test('onLock terpicu setelah idle, touch menunda, stop mencegah',
        () async {
      var locked = 0;
      final lock = VaultAutoLock(
        onLock: () => locked++,
        idleTimeout: const Duration(milliseconds: 30),
      );
      lock.touch();
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(locked, 1);
      expect(lock.isArmed, isFalse);

      lock.touch();
      await Future<void>.delayed(const Duration(milliseconds: 15));
      lock.touch();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(locked, 1);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(locked, 2);

      lock.touch();
      lock.stop();
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(locked, 2);
    });
  });

  group('VaultModes + recovery shares', () {
    late Directory tmp;
    late String vault;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('simpul-recovery-test');
      vault = '${tmp.path}/vault';
      await Directory(vault).create(recursive: true);
      await File('$vault/catatan.md').writeAsString(
        '---\ntitle: Catatan\n---\nisi catatan rahasia\n',
      );
    });

    tearDown(() async {
      await tmp.delete(recursive: true);
    });

    test('lock dengan recovery-shares, unlock tanpa password via share',
        () async {
      final result = await VaultModes.lock(
        vault,
        password: 'sandi-kuat',
        mode: 'm3',
        recoveryShares: 5,
        recoveryThreshold: 3,
      );
      expect(result.shares.length, 5);
      expect(VaultModes.isLocked(vault), isTrue);

      final unlocked = await VaultModes.unlock(
        vault,
        recoveryShares: [result.shares[0], result.shares[2], result.shares[4]],
      );
      expect(unlocked.decrypted, contains('catatan.md'));
      expect(VaultModes.isLocked(vault), isFalse);
      expect(File('$vault/catatan.md').readAsStringSync(), contains('rahasia'));
    });

    test('unlock menolak share yang tidak cukup tanpa mengubah vault',
        () async {
      final result = await VaultModes.lock(
        vault,
        password: 'sandi-kuat',
        mode: 'm3',
        recoveryShares: 4,
        recoveryThreshold: 3,
      );
      expect(
        () => VaultModes.unlock(
          vault,
          recoveryShares: result.shares.sublist(0, 2),
        ),
        throwsA(isA<VaultRecoveryException>()),
      );
      expect(VaultModes.isLocked(vault), isTrue);
      expect(VaultCrypto.isFileEncrypted('$vault/catatan.md'), isTrue);
    });

    test('unlock tetap bisa dengan password setelah lock dengan share',
        () async {
      final result = await VaultModes.lock(
        vault,
        password: 'sandi-kuat',
        mode: 'm3',
        recoveryShares: 3,
        recoveryThreshold: 2,
      );
      expect(result.shares, isNotEmpty);
      final unlocked = await VaultModes.unlock(vault, password: 'sandi-kuat');
      expect(unlocked.decrypted, contains('catatan.md'));
    });
  });
}

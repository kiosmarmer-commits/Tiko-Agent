import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:cryptography/dart.dart';

/// Argon2id parameters stored in every crate header (SEC-05). Defaults follow
/// the OWASP memory-hard guidance (19 MiB, t=2, p=1).
class KdfParams {
  const KdfParams({
    this.memoryKib = 19456,
    this.iterations = 2,
    this.parallelism = 1,
    this.saltLength = 16,
  });

  final int memoryKib;
  final int iterations;
  final int parallelism;
  final int saltLength;

  Map<String, Object?> toJson() => {
        'algo': 'argon2id',
        'memory_kib': memoryKib,
        'iterations': iterations,
        'parallelism': parallelism,
        'salt_length': saltLength,
      };

  static KdfParams fromJson(Map<String, Object?> json) {
    if (json['algo'] != null && json['algo'] != 'argon2id') {
      throw VaultCryptoException('KDF tidak dikenal: ${json['algo']}');
    }
    return KdfParams(
      memoryKib: (json['memory_kib'] as num?)?.toInt() ?? 19456,
      iterations: (json['iterations'] as num?)?.toInt() ?? 2,
      parallelism: (json['parallelism'] as num?)?.toInt() ?? 1,
      saltLength: (json['salt_length'] as num?)?.toInt() ?? 16,
    );
  }
}

class VaultCryptoException implements Exception {
  VaultCryptoException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Vault encryption core (SEC-03..09). AEAD is XChaCha20-Poly1305 from the
/// audited `cryptography` package; the KDF is Argon2id. Key hierarchy
/// (SEC-07): password → KEK (Argon2id) → vault key (wrapped in the key
/// crate) → per-file DEK (wrapped in every crate). Nonces are random per
/// encryption (SEC-08) and the crate format is versioned (SEC-09).
///
/// Crate layout v1:
/// `magic(8) | version(1) | algo(1) | kdf(algo(1) m(4) t(4) p(1)
/// saltLen(1) salt) | wrappedKey(len(2) nonce(24) mac(16) ct) |
/// nonce(24) | mac(16) | ciphertext`
class VaultCrypto {
  VaultCrypto._(this._vaultKey, this.kdf);

  /// Wraps an already-known vault key (e.g. reconstructed from Shamir
  /// recovery shares, SEC-06) without re-deriving from a password.
  VaultCrypto.withVaultKey(
    List<int> vaultKey, {
    this.kdf = const KdfParams(),
  })  : _vaultKey = Uint8List.fromList(vaultKey),
        _wiped = false;

  bool _wiped = false;

  /// True after [wipe] — the instance can no longer encrypt or decrypt.
  bool get isWiped => _wiped;

  /// Zeroes the in-memory vault key (SEC-16 auto-lock). Any later
  /// encrypt/decrypt throws [VaultCryptoException] instead of silently
  /// working with stale key material.
  void wipe() {
    if (_vaultKey is Uint8List) {
      _vaultKey.fillRange(0, _vaultKey.length, 0);
    }
    _wiped = true;
  }

  /// Exposes the raw vault key for recovery-key splitting (SEC-06). Treat
  /// the result as a secret: split it, then let it go out of scope.
  List<int> vaultKeyBytes() {
    if (_wiped) {
      throw VaultCryptoException('kunci vault sudah di-wipe (auto-lock)');
    }
    return Uint8List.fromList(_vaultKey);
  }

  static const magic = 'SMPLCRT1';
  static const formatVersion = 1;
  static const _algoXchacha20Poly1305 = 1;
  static const _kdfArgon2id = 1;
  static const _nonceLength = 24;

  static final DartXchacha20 _aead = const DartXchacha20.poly1305Aead();

  final List<int> _vaultKey;
  final KdfParams kdf;

  static bool looksEncrypted(List<int> bytes) =>
      bytes.length > 8 && utf8.decode(bytes.sublist(0, 8), allowMalformed: true) == magic;

  static bool isFileEncrypted(String path) {
    final file = File(path);
    if (!file.existsSync()) return false;
    return looksEncrypted(file.readAsBytesSync());
  }

  /// Creates a fresh random vault key wrapped under a KEK derived from
  /// [password] with a fresh random salt.
  static Future<({VaultCrypto crypto, List<int> keyCrate})> create({
    required String password,
    KdfParams kdf = const KdfParams(),
  }) async {
    final vaultKey = _randomBytes(32);
    final crypto = VaultCrypto._(vaultKey, kdf);
    final crate = await crypto._sealKeyCrate(password);
    return (crypto: crypto, keyCrate: crate);
  }

  /// Unlocks a vault key crate: derives the KEK from [password] using the
  /// crate's KDF header, then unwraps the vault key. A wrong password or a
  /// tampered crate throws [VaultCryptoException].
  static Future<VaultCrypto> open(List<int> keyCrate, {required String password}) async {
    final header = _parseHeader(keyCrate);
    final kek = await _deriveKek(password, header.salt, header.kdf);
    final vaultKey = await _unwrap(header.wrapped, kek, what: 'kunci vault');
    return VaultCrypto._(vaultKey, header.kdf);
  }

  /// The key crate bytes to persist at `.simpul/vault-key.crate`.
  Future<List<int>> sealKeyCrate(String password) => _sealKeyCrate(password);

  Future<List<int>> _sealKeyCrate(String password) async {
    final salt = _randomBytes(kdf.saltLength);
    final kek = await _deriveKek(password, salt, kdf);
    final wrapped = await _wrap(_vaultKey, kek);
    return _buildCrate(kdf: kdf, salt: salt, wrapped: wrapped, payload: _vaultKey);
  }

  /// Encrypts [plain] under a fresh per-file DEK (SEC-07/08).
  List<int> encryptBytes(List<int> plain) {
    _ensureNotWiped();
    final dek = _randomBytes(32);
    final wrapped = _wrapSync(dek, _vaultKey);
    final box = _aead.encryptSync(
      plain,
      secretKey: SecretKeyData(dek),
      nonce: _randomBytes(_nonceLength),
    );
    return _buildCrate(
      kdf: kdf,
      salt: const [],
      wrapped: wrapped,
      payload: box.cipherText,
      nonce: box.nonce,
      mac: box.mac.bytes,
    );
  }

  /// Decrypts crate bytes; tampering or a wrong key throws
  /// [VaultCryptoException] (fail-closed, SEC-I04).
  List<int> decryptBytes(List<int> stored) {
    _ensureNotWiped();
    final header = _parseHeader(stored);
    final dek = _unwrapSync(header.wrapped, _vaultKey, what: 'kunci data');
    final body = _BodyOffsets.parse(stored, header.wrappedEnd);
    try {
      return _aead.decryptSync(
        SecretBox(
          stored.sublist(body.cipherStart),
          nonce: stored.sublist(body.nonceStart, body.macStart),
          mac: Mac(stored.sublist(body.macStart, body.cipherStart)),
        ),
        secretKey: SecretKeyData(dek),
      );
    } on SecretBoxAuthenticationError {
      throw VaultCryptoException('dekripsi gagal: data rusak atau kunci salah');
    }
  }

  /// Encrypts a plain file in place (atomic tmp+rename).
  Future<void> encryptFileInPlace(String path) async {
    final raw = File(path).readAsBytesSync();
    if (looksEncrypted(raw)) return;
    await writeBytesAtomically(path, encryptBytes(raw));
  }

  /// Decrypts a crate file in place (atomic tmp+rename).
  Future<void> decryptFileInPlace(String path) async {
    final raw = File(path).readAsBytesSync();
    await writeBytesAtomically(path, decryptBytes(raw));
  }

  void _ensureNotWiped() {
    if (_wiped) {
      throw VaultCryptoException('kunci vault sudah di-wipe (auto-lock)');
    }
  }

  static Future<void> writeBytesAtomically(String path, List<int> bytes) async {
    final file = File(path);
    await file.parent.create(recursive: true);
    final tmp = '$path.tmp';
    await File(tmp).writeAsBytes(bytes, flush: true);
    await File(tmp).rename(path);
  }
}

/// Fail-closed byte I/O for vault index files. When [crypto] is null but the
/// file on disk is an encrypted crate, reads throw instead of silently
/// returning ciphertext (SEC-11/12).
class VaultFiles {
  const VaultFiles._();

  static List<int> readBytes(String path, {VaultCrypto? crypto}) {
    final bytes = File(path).readAsBytesSync();
    if (crypto == null) {
      if (VaultCrypto.looksEncrypted(bytes)) {
        throw VaultCryptoException(
          'file terenkripsi dibaca tanpa kunci: $path (vault terkunci)',
        );
      }
      return bytes;
    }
    if (!VaultCrypto.looksEncrypted(bytes)) {
      throw VaultCryptoException('file bukan crate terenkripsi: $path');
    }
    return crypto.decryptBytes(bytes);
  }

  static Future<void> writeBytes(
    String path,
    List<int> bytes, {
    VaultCrypto? crypto,
  }) async {
    final stored = crypto == null ? bytes : crypto.encryptBytes(bytes);
    await VaultCrypto.writeBytesAtomically(path, stored);
  }

  static bool exists(String path) => File(path).existsSync();

  static String readString(String path, {VaultCrypto? crypto}) =>
      utf8.decode(readBytes(path, crypto: crypto));

  static Future<void> writeString(String path, String value, {VaultCrypto? crypto}) =>
      writeBytes(path, utf8.encode(value), crypto: crypto);
}

class _CrateHeader {
  _CrateHeader({
    required this.kdf,
    required this.salt,
    required this.wrapped,
    required this.wrappedEnd,
  });

  final KdfParams kdf;
  final List<int> salt;
  final List<int> wrapped;
  final int wrappedEnd;
}

class _BodyOffsets {
  _BodyOffsets.parse(List<int> bytes, int start) {
    if (bytes.length < start + _kNonce + _kMac) {
      throw VaultCryptoException('format crate tidak lengkap');
    }
    nonceStart = start;
    macStart = start + _kNonce;
    cipherStart = macStart + _kMac;
  }

  static const _kNonce = 24;
  static const _kMac = 16;

  late final int nonceStart;
  late final int macStart;
  late final int cipherStart;
}

_CrateHeader _parseHeader(List<int> bytes) {
  const fixed = 8 + 1 + 1 + 1 + 4 + 4 + 1 + 1;
  if (bytes.length < fixed ||
      utf8.decode(bytes.sublist(0, 8), allowMalformed: true) != VaultCrypto.magic) {
    throw VaultCryptoException('bukan crate vault (magic tidak cocok)');
  }
  if (bytes[8] != VaultCrypto.formatVersion) {
    throw VaultCryptoException('versi format crate tidak didukung: ${bytes[8]}');
  }
  if (bytes[9] != VaultCrypto._algoXchacha20Poly1305) {
    throw VaultCryptoException('algoritma AEAD tidak dikenal: ${bytes[9]}');
  }
  if (bytes[10] != VaultCrypto._kdfArgon2id) {
    throw VaultCryptoException('KDF tidak dikenal: ${bytes[10]}');
  }
  final kdf = KdfParams(
    memoryKib: _readUint32(bytes, 11),
    iterations: _readUint32(bytes, 15),
    parallelism: bytes[19],
    saltLength: bytes[20],
  );
  if (bytes.length < fixed + kdf.saltLength) {
    throw VaultCryptoException('format crate tidak lengkap (salt)');
  }
  final salt = bytes.sublist(21, 21 + kdf.saltLength);
  final wrappedStart = 21 + kdf.saltLength;
  if (bytes.length < wrappedStart + 2) {
    throw VaultCryptoException('format crate tidak lengkap (kunci terbungkus)');
  }
  final wrappedLen = _readUint16(bytes, wrappedStart);
  final wrappedBodyStart = wrappedStart + 2;
  if (bytes.length < wrappedBodyStart + wrappedLen) {
    throw VaultCryptoException('format crate tidak lengkap (kunci terbungkus)');
  }
  final wrapped = bytes.sublist(wrappedBodyStart, wrappedBodyStart + wrappedLen);
  return _CrateHeader(
    kdf: kdf,
    salt: salt,
    wrapped: wrapped,
    wrappedEnd: wrappedBodyStart + wrappedLen,
  );
}

int _readUint32(List<int> bytes, int offset) =>
    bytes[offset] | (bytes[offset + 1] << 8) | (bytes[offset + 2] << 16) | (bytes[offset + 3] << 24);

int _readUint16(List<int> bytes, int offset) => bytes[offset] | (bytes[offset + 1] << 8);

Future<SecretKey> _deriveKek(String password, List<int> salt, KdfParams kdf) async {
  final argon = Argon2id(
    memory: kdf.memoryKib,
    iterations: kdf.iterations,
    parallelism: kdf.parallelism,
    hashLength: 32,
  );
  final derived = await argon.deriveKey(
    secretKey: SecretKey(utf8.encode(password)),
    nonce: salt,
  );
  return derived;
}

Future<List<int>> _wrap(List<int> key, SecretKey kek) async {
  final box = await VaultCrypto._aead.encrypt(
    key,
    secretKey: kek,
    nonce: _randomBytes(24),
  );
  return _encodeWrapped(box);
}

List<int> _wrapSync(List<int> key, List<int> kek) {
  final box = VaultCrypto._aead.encryptSync(
    key,
    secretKey: SecretKeyData(kek),
    nonce: _randomBytes(24),
  );
  return _encodeWrapped(box);
}

/// Encodes `nonce(24) | mac(16) | ciphertext` — the 2-byte length prefix is
/// written by the caller (_buildCrate).
List<int> _encodeWrapped(SecretBox box) {
  if (box.nonce.length != 24 || box.mac.bytes.length != 16) {
    throw VaultCryptoException('parameter AEAD tidak sesuai format crate');
  }
  final out = BytesBuilder();
  out.add(box.nonce);
  out.add(box.mac.bytes);
  out.add(box.cipherText);
  return out.toBytes();
}

Future<List<int>> _unwrap(List<int> wrapped, SecretKey kek, {required String what}) async {
  if (wrapped.length < 40) {
    throw VaultCryptoException('kunci terbungkus tidak lengkap');
  }
  try {
    return await VaultCrypto._aead.decrypt(
      SecretBox(
        wrapped.sublist(40),
        nonce: wrapped.sublist(0, 24),
        mac: Mac(wrapped.sublist(24, 40)),
      ),
      secretKey: kek,
    );
  } on SecretBoxAuthenticationError {
    throw VaultCryptoException('kata sandi salah atau $what rusak');
  }
}

List<int> _unwrapSync(List<int> wrapped, List<int> kek, {required String what}) {
  if (wrapped.length < 40) {
    throw VaultCryptoException('kunci terbungkus tidak lengkap');
  }
  try {
    return VaultCrypto._aead.decryptSync(
      SecretBox(
        wrapped.sublist(40),
        nonce: wrapped.sublist(0, 24),
        mac: Mac(wrapped.sublist(24, 40)),
      ),
      secretKey: SecretKeyData(kek),
    );
  } on SecretBoxAuthenticationError {
    throw VaultCryptoException('kunci salah atau $what rusak');
  }
}

List<int> _buildCrate({
  required KdfParams kdf,
  required List<int> salt,
  required List<int> wrapped,
  required List<int> payload,
  List<int>? nonce,
  List<int>? mac,
}) {
  final bodyNonce = nonce ?? _randomBytes(24);
  final bodyMac = mac ?? const [];
  final out = BytesBuilder();
  out.add(utf8.encode(VaultCrypto.magic));
  out.addByte(VaultCrypto.formatVersion);
  out.addByte(VaultCrypto._algoXchacha20Poly1305);
  out.addByte(VaultCrypto._kdfArgon2id);
  out.add(_uint32(kdf.memoryKib));
  out.add(_uint32(kdf.iterations));
  out.addByte(kdf.parallelism);
  out.addByte(salt.length);
  out.add(salt);
  out.addByte(wrapped.length & 0xFF);
  out.addByte((wrapped.length >> 8) & 0xFF);
  out.add(wrapped);
  out.add(bodyNonce);
  out.add(bodyMac);
  out.add(payload);
  return out.toBytes();
}

Uint8List _uint32(int value) => Uint8List(4)
  ..[0] = value & 0xFF
  ..[1] = (value >> 8) & 0xFF
  ..[2] = (value >> 16) & 0xFF
  ..[3] = (value >> 24) & 0xFF;

final Random _secureRandom = Random.secure();

Uint8List _randomBytes(int length) =>
    Uint8List.fromList(List<int>.generate(length, (_) => _secureRandom.nextInt(256)));

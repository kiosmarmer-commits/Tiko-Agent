import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

class SecretStoreException implements Exception {
  SecretStoreException(this.message);

  final String message;

  @override
  String toString() => 'SecretStoreException: $message';
}

/// Encrypted local secret store (AGD-07, B-01). Not a replacement for the OS
/// keychain. Payload is sealed with XChaCha20-Poly1305 from the audited
/// `cryptography` package under an Argon2id-derived key (OWASP memory-hard
/// defaults: 19 MiB, t=2, p=1). File layout v2:
/// `TSS2 | salt(16) | nonce(24) | ciphertext | mac(16)`.
///
/// Files written by the legacy XOR-LCG implementation (base64 text without
/// the `TSS2` magic) are decrypted once, rewritten in v2, and the legacy
/// bytes are replaced atomically.
class SecretStore {
  SecretStore({required this.path, required this.passphrase});

  final String path;
  final String passphrase;

  static final Xchacha20 _aead = Xchacha20.poly1305Aead();
  static const String _magic = 'TSS2';
  static const int _saltLength = 16;
  static const int _nonceLength = 24;
  static const int _macLength = 16;

  Future<void> write(String key, String value) async {
    final all = await _readAll();
    all[key] = value;
    await _writeAll(all);
  }

  Future<String?> read(String key) async {
    final all = await _readAll();
    return all[key];
  }

  Future<void> delete() async {
    final f = File(path);
    if (await f.exists()) await f.delete();
  }

  Future<Map<String, String>> _readAll() async {
    final f = File(path);
    if (!await f.exists()) return {};
    final raw = await f.readAsBytes();
    if (_hasMagic(raw)) {
      return _readV2(raw);
    }
    final legacy = _readLegacy(raw);
    if (legacy != null) {
      await _writeAll(legacy);
      return legacy;
    }
    throw SecretStoreException('File secret rusak atau bukan format dikenal');
  }

  bool _hasMagic(List<int> raw) =>
      raw.length >= _magic.length &&
      utf8.decode(raw.sublist(0, _magic.length), allowMalformed: true) ==
          _magic;

  Future<Map<String, String>> _readV2(Uint8List raw) async {
    if (raw.length <
        _magic.length + _saltLength + _nonceLength + _macLength) {
      throw SecretStoreException('File secret terlalu pendek');
    }
    var offset = _magic.length;
    final salt = raw.sublist(offset, offset + _saltLength);
    offset += _saltLength;
    final nonce = raw.sublist(offset, offset + _nonceLength);
    offset += _nonceLength;
    final cipher = raw.sublist(offset, raw.length - _macLength);
    final mac = Mac(raw.sublist(raw.length - _macLength));
    try {
      final key = await _deriveKey(salt);
      final plain = await _aead.decrypt(
        SecretBox(cipher, nonce: nonce, mac: mac),
        secretKey: key,
      );
      return _decodeMap(plain);
    } on SecretStoreException {
      rethrow;
    } catch (_) {
      throw SecretStoreException('Integritas file secret gagal (MAC mismatch)');
    }
  }

  Map<String, String>? _readLegacy(List<int> raw) {
    try {
      final decoded = base64Decode(utf8.decode(raw));
      if (decoded.length <= _saltLength) return null;
      final salt = decoded.sublist(0, _saltLength);
      final data = decoded.sublist(_saltLength);
      final plain = _xor(data, _keystream(salt, data.length));
      return _decodeMap(plain);
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeAll(Map<String, String> map) async {
    final salt = _randomBytes(_saltLength);
    final key = await _deriveKey(salt);
    final box = await _aead.encrypt(
      utf8.encode(jsonEncode(map)),
      secretKey: key,
      nonce: _randomBytes(_nonceLength),
    );
    final out = BytesBuilder()
      ..add(utf8.encode(_magic))
      ..add(salt)
      ..add(box.nonce)
      ..add(box.cipherText)
      ..add(box.mac.bytes);
    final target = File(path);
    await target.parent.create(recursive: true);
    final tmp = File('${target.path}.tmp');
    await tmp.writeAsBytes(out.toBytes(), flush: true);
    if (!Platform.isWindows) {
      final result = await Process.run('chmod', ['600', tmp.path]);
      if (result.exitCode != 0) {
        try {
          await tmp.delete();
        } catch (_) {} // best-effort
        throw SecretStoreException(
          'Tidak dapat mengamankan permission file secret: ${result.stderr}',
        );
      }
    }
    try {
      await tmp.rename(target.path);
    } on FileSystemException {
      if (await target.exists()) await target.delete();
      await tmp.rename(target.path);
    }
  }

  Future<SecretKey> _deriveKey(List<int> salt) {
    final argon = Argon2id(
      memory: 19456,
      iterations: 2,
      parallelism: 1,
      hashLength: 32,
    );
    return argon.deriveKey(
      secretKey: SecretKey(utf8.encode(passphrase)),
      nonce: salt,
    );
  }

  Map<String, String> _decodeMap(List<int> plain) {
    final map = jsonDecode(utf8.decode(plain)) as Map<String, dynamic>;
    return map.map((k, v) => MapEntry(k, '$v'));
  }

  Uint8List _keystream(List<int> salt, int len) {
    final seed = utf8.encode(passphrase) + salt;
    final out = Uint8List(len);
    var state = 0;
    for (final b in seed) {
      state = (state * 31 + b) & 0x7fffffff;
    }
    for (var i = 0; i < len; i++) {
      state = (state * 1103515245 + 12345) & 0x7fffffff;
      out[i] = (state >> 16) & 0xff;
    }
    return out;
  }

  Uint8List _xor(List<int> data, Uint8List ks) {
    final out = Uint8List(data.length);
    for (var i = 0; i < data.length; i++) {
      out[i] = data[i] ^ ks[i];
    }
    return out;
  }

  Uint8List _randomBytes(int n) {
    final r = Random.secure();
    return Uint8List.fromList(List.generate(n, (_) => r.nextInt(256)));
  }
}

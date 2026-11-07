import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

/// Lightweight local secret store (AGD-07). Not a replacement for OS keychain.
/// Format: base64(salt + xor(payload, keystream from passphrase)).
class SecretStore {
  SecretStore({required this.path, required this.passphrase});

  final String path;
  final String passphrase;

  Future<void> write(String key, String value) async {
    final all = await _readAll();
    all[key] = value;
    await _writeAll(all);
  }

  Future<String?> read(String key) async {
    final all = await _readAll();
    return all[key];
  }

  Future<Map<String, String>> _readAll() async {
    final f = File(path);
    if (!await f.exists()) return {};
    try {
      final raw = base64Decode(await f.readAsString());
      final salt = raw.sublist(0, 16);
      final data = raw.sublist(16);
      final plain = _xor(data, _keystream(salt, data.length));
      final map = jsonDecode(utf8.decode(plain)) as Map<String, dynamic>;
      return map.map((k, v) => MapEntry(k, '$v'));
    } catch (_) {
      return {};
    }
  }

  Future<void> _writeAll(Map<String, String> map) async {
    final salt = _randomBytes(16);
    final payload = utf8.encode(jsonEncode(map));
    final enc = _xor(payload, _keystream(salt, payload.length));
    final out = BytesBuilder()
      ..add(salt)
      ..add(enc);
    await File(path).parent.create(recursive: true);
    await File(path).writeAsString(base64Encode(out.toBytes()));
  }

  Uint8List _keystream(List<int> salt, int len) {
    final seed = utf8.encode(passphrase) + salt;
    // simple expand
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

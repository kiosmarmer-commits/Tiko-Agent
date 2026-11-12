import 'dart:typed_data';

const _sigma = [0x61707865, 0x3320646e, 0x79622d32, 0x6b206574];

int _rotl(int x, int n) =>
    ((x << n) | (x >>> (32 - n))) & 0xffffffff;

int _load32(List<int> b, int i) =>
    b[i] | (b[i + 1] << 8) | (b[i + 2] << 16) | (b[i + 3] << 24);

void _store32(List<int> b, int i, int w) {
  b[i] = w & 0xff;
  b[i + 1] = (w >> 8) & 0xff;
  b[i + 2] = (w >> 16) & 0xff;
  b[i + 3] = (w >> 24) & 0xff;
}

List<int> _salsa20Rounds(List<int> input, {required bool hsalsa}) {
  final x = List<int>.of(input);
  for (var i = 0; i < 10; i++) {
    x[4] ^= _rotl((x[0] + x[12]) & 0xffffffff, 7);
    x[8] ^= _rotl((x[4] + x[0]) & 0xffffffff, 9);
    x[12] ^= _rotl((x[8] + x[4]) & 0xffffffff, 13);
    x[0] ^= _rotl((x[12] + x[8]) & 0xffffffff, 18);
    x[9] ^= _rotl((x[5] + x[1]) & 0xffffffff, 7);
    x[13] ^= _rotl((x[9] + x[5]) & 0xffffffff, 9);
    x[1] ^= _rotl((x[13] + x[9]) & 0xffffffff, 13);
    x[5] ^= _rotl((x[1] + x[13]) & 0xffffffff, 18);
    x[14] ^= _rotl((x[10] + x[6]) & 0xffffffff, 7);
    x[2] ^= _rotl((x[14] + x[10]) & 0xffffffff, 9);
    x[6] ^= _rotl((x[2] + x[14]) & 0xffffffff, 13);
    x[10] ^= _rotl((x[6] + x[2]) & 0xffffffff, 18);
    x[3] ^= _rotl((x[15] + x[11]) & 0xffffffff, 7);
    x[7] ^= _rotl((x[3] + x[15]) & 0xffffffff, 9);
    x[11] ^= _rotl((x[7] + x[3]) & 0xffffffff, 13);
    x[15] ^= _rotl((x[11] + x[7]) & 0xffffffff, 18);

    x[1] ^= _rotl((x[0] + x[3]) & 0xffffffff, 7);
    x[2] ^= _rotl((x[1] + x[0]) & 0xffffffff, 9);
    x[3] ^= _rotl((x[2] + x[1]) & 0xffffffff, 13);
    x[0] ^= _rotl((x[3] + x[2]) & 0xffffffff, 18);
    x[6] ^= _rotl((x[5] + x[4]) & 0xffffffff, 7);
    x[7] ^= _rotl((x[6] + x[5]) & 0xffffffff, 9);
    x[4] ^= _rotl((x[7] + x[6]) & 0xffffffff, 13);
    x[5] ^= _rotl((x[4] + x[7]) & 0xffffffff, 18);
    x[11] ^= _rotl((x[10] + x[9]) & 0xffffffff, 7);
    x[8] ^= _rotl((x[11] + x[10]) & 0xffffffff, 9);
    x[9] ^= _rotl((x[8] + x[11]) & 0xffffffff, 13);
    x[10] ^= _rotl((x[9] + x[8]) & 0xffffffff, 18);
    x[12] ^= _rotl((x[15] + x[14]) & 0xffffffff, 7);
    x[13] ^= _rotl((x[12] + x[15]) & 0xffffffff, 9);
    x[14] ^= _rotl((x[13] + x[12]) & 0xffffffff, 13);
    x[15] ^= _rotl((x[14] + x[13]) & 0xffffffff, 18);
  }
  if (hsalsa) {
    return [
      x[0], x[5], x[10], x[15], x[6], x[7], x[8], x[9],
    ];
  }
  return [for (var i = 0; i < 16; i++) (x[i] + input[i]) & 0xffffffff];
}

/// HSalsa20: derives a 32-byte subkey from [key] and the first 16 bytes of
/// the nonce.
List<int> _hsalsa20(List<int> key, List<int> nonce16) {
  final state = <int>[
    _sigma[0],
    _load32(key, 0), _load32(key, 4), _load32(key, 8), _load32(key, 12),
    _sigma[1],
    _load32(nonce16, 0), _load32(nonce16, 4), _load32(nonce16, 8),
    _load32(nonce16, 12),
    _sigma[2],
    _load32(key, 16), _load32(key, 20), _load32(key, 24), _load32(key, 28),
    _sigma[3],
  ];
  final out = _salsa20Rounds(state, hsalsa: true);
  final bytes = Uint8List(32);
  for (var i = 0; i < 8; i++) {
    _store32(bytes, i * 4, out[i]);
  }
  return bytes;
}

/// Salsa20 keystream of [length] bytes from a 32-byte [key] and 8-byte
/// [nonce], counter starting at zero.
List<int> _salsa20Stream(List<int> key, List<int> nonce8, int length) {
  final out = Uint8List(length);
  var counter = 0;
  for (var off = 0; off < length; off += 64, counter++) {
    final state = <int>[
      _sigma[0],
      _load32(key, 0), _load32(key, 4), _load32(key, 8), _load32(key, 12),
      _sigma[1],
      _load32(nonce8, 0), _load32(nonce8, 4),
      counter & 0xffffffff, (counter >>> 32) & 0xffffffff,
      _sigma[2],
      _load32(key, 16), _load32(key, 20), _load32(key, 24), _load32(key, 28),
      _sigma[3],
    ];
    final block = _salsa20Rounds(state, hsalsa: false);
    final n = length - off < 64 ? length - off : 64;
    for (var i = 0; i < n; i++) {
      out[off + i] = (block[i >>> 2] >> ((i & 3) * 8)) & 0xff;
    }
  }
  return out;
}

BigInt _leInt(List<int> bytes) {
  var v = BigInt.zero;
  for (var i = bytes.length - 1; i >= 0; i--) {
    v = (v << 8) | BigInt.from(bytes[i]);
  }
  return v;
}

List<int> _leBytes(BigInt v, int length) {
  final out = Uint8List(length);
  for (var i = 0; i < length; i++) {
    out[i] = (v & BigInt.from(0xff)).toInt();
    v = v >> 8;
  }
  return out;
}

/// Poly1305 one-time authenticator over [message] with a 32-byte [key]
/// (first 16 bytes clamped as r, last 16 bytes used as s).
List<int> _poly1305(List<int> message, List<int> key) {
  final p = (BigInt.one << 130) - BigInt.from(5);
  final clamp = BigInt.parse('0ffffffc0ffffffc0ffffffc0fffffff', radix: 16);
  final r = _leInt(key.sublist(0, 16)) & clamp;
  final s = _leInt(key.sublist(16, 32));
  var h = BigInt.zero;
  for (var i = 0; i < message.length; i += 16) {
    final end = i + 16 < message.length ? i + 16 : message.length;
    final block = message.sublist(i, end);
    final n = _leInt(block) | (BigInt.one << (8 * block.length));
    h = ((h + n) * r) % p;
  }
  return _leBytes((h + s) & ((BigInt.one << 128) - BigInt.one), 16);
}

bool _constantTimeEquals(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}

/// Public Poly1305 wrapper for the AEAD module (`xchacha20_aead.dart`).
List<int> naclPoly1305(List<int> message, List<int> key) =>
    _poly1305(message, key);

/// NaCl `secretbox` (XSalsa20-Poly1305) with a 24-byte nonce and 32-byte
/// key: output is the 16-byte Poly1305 tag followed by the ciphertext.
///
/// Pure-Dart port used by Discord voice mode `xsalsa20_poly1305`, verified
/// against libsodium/PyNaCl test vectors.
List<int> naclSecretbox(
  List<int> message,
  List<int> nonce24,
  List<int> key32,
) {
  if (nonce24.length != 24) {
    throw ArgumentError.value(nonce24.length, 'nonce', 'must be 24 bytes');
  }
  if (key32.length != 32) {
    throw ArgumentError.value(key32.length, 'key', 'must be 32 bytes');
  }
  final subkey = _hsalsa20(key32, nonce24.sublist(0, 16));
  final stream = _salsa20Stream(
    subkey,
    nonce24.sublist(16, 24),
    message.length + 32,
  );
  final cipher = <int>[
    for (var i = 0; i < message.length; i++) message[i] ^ stream[32 + i],
  ];
  final tag = _poly1305(cipher, stream.sublist(0, 32));
  return [...tag, ...cipher];
}

/// Opens a [naclSecretbox] box; throws [ArgumentError] when the tag does
/// not authenticate. Returns the plaintext message.
List<int> naclSecretboxOpen(
  List<int> box,
  List<int> nonce24,
  List<int> key32,
) {
  if (nonce24.length != 24) {
    throw ArgumentError.value(nonce24.length, 'nonce', 'must be 24 bytes');
  }
  if (key32.length != 32) {
    throw ArgumentError.value(key32.length, 'key', 'must be 32 bytes');
  }
  if (box.length < 16) {
    throw ArgumentError('box shorter than the 16-byte tag');
  }
  final tag = box.sublist(0, 16);
  final cipher = box.sublist(16);
  final subkey = _hsalsa20(key32, nonce24.sublist(0, 16));
  final stream = _salsa20Stream(
    subkey,
    nonce24.sublist(16, 24),
    cipher.length + 32,
  );
  final expected = _poly1305(cipher, stream.sublist(0, 32));
  if (!_constantTimeEquals(expected, tag)) {
    throw ArgumentError('secretbox authentication failed');
  }
  final message = <int>[
    for (var i = 0; i < cipher.length; i++) cipher[i] ^ stream[32 + i],
  ];
  return message;
}

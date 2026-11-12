import 'dart:typed_data';

import 'nacl_secretbox.dart' show naclPoly1305;

/// ChaCha20 / HChaCha20 / AEAD_XChaCha20_Poly1305 (pure Dart).
///
/// Implements the IETF constructions:
/// - ChaCha20 block function and stream cipher (RFC 8439, 96-bit nonce).
/// - HChaCha20 subkey derivation (draft-irtf-cfrg-xchacha §2.2).
/// - AEAD_CHACHA20_POLY1305 (RFC 8439 §2.8) and
///   AEAD_XCHACHA20_POLY1305 (draft-irtf-cfrg-xchacha §2, 192-bit nonce).
///
/// Used by the Discord voice gateway's `aead_xchacha20_poly1305` mode.
const _chachaConstants = [0x61707865, 0x3320646e, 0x79622d32, 0x6b206574];

int _rotl(int x, int n) => ((x << n) | (x >>> (32 - n))) & 0xFFFFFFFF;

int _load32(List<int> b, int i) =>
    b[i] | (b[i + 1] << 8) | (b[i + 2] << 16) | (b[i + 3] << 24);

void _store32(List<int> b, int i, int w) {
  b[i] = w & 0xff;
  b[i + 1] = (w >> 8) & 0xff;
  b[i + 2] = (w >> 16) & 0xff;
  b[i + 3] = (w >> 24) & 0xff;
}

void _quarterRound(List<int> x, int a, int b, int c, int d) {
  x[a] = (x[a] + x[b]) & 0xFFFFFFFF;
  x[d] = _rotl(x[d] ^ x[a], 16);
  x[c] = (x[c] + x[d]) & 0xFFFFFFFF;
  x[b] = _rotl(x[b] ^ x[c], 12);
  x[a] = (x[a] + x[b]) & 0xFFFFFFFF;
  x[d] = _rotl(x[d] ^ x[a], 8);
  x[c] = (x[c] + x[d]) & 0xFFFFFFFF;
  x[b] = _rotl(x[b] ^ x[c], 7);
}

void _rounds(List<int> x) {
  for (var i = 0; i < 10; i++) {
    _quarterRound(x, 0, 4, 8, 12);
    _quarterRound(x, 1, 5, 9, 13);
    _quarterRound(x, 2, 6, 10, 14);
    _quarterRound(x, 3, 7, 11, 15);
    _quarterRound(x, 0, 5, 10, 15);
    _quarterRound(x, 1, 6, 11, 12);
    _quarterRound(x, 2, 7, 8, 13);
    _quarterRound(x, 3, 4, 9, 14);
  }
}

List<int> _stateFrom(List<int> key, List<int> nonce12, int counter) {
  final state = List<int>.filled(16, 0);
  for (var i = 0; i < 4; i++) {
    state[i] = _chachaConstants[i];
  }
  for (var i = 0; i < 8; i++) {
    state[4 + i] = _load32(key, i * 4);
  }
  state[12] = counter & 0xFFFFFFFF;
  for (var i = 0; i < 3; i++) {
    state[13 + i] = _load32(nonce12, i * 4);
  }
  return state;
}

/// One ChaCha20 block: 64 keystream bytes (RFC 8439 §2.3).
List<int> _chachaBlock(List<int> state) {
  final x = List<int>.of(state);
  _rounds(x);
  final out = List<int>.filled(64, 0);
  for (var i = 0; i < 16; i++) {
    _store32(out, i * 4, (x[i] + state[i]) & 0xFFFFFFFF);
  }
  return out;
}

/// ChaCha20 keystream (RFC 8439 §2.4), starting at block [counter].
List<int> _chacha20Stream(
  List<int> key,
  List<int> nonce12,
  int length, {
  int counter = 1,
}) {
  final state = _stateFrom(key, nonce12, counter);
  final out = BytesBuilder();
  var block = 0;
  while (out.length < length) {
    state[12] = (counter + block) & 0xFFFFFFFF;
    out.add(_chachaBlock(state));
    block++;
  }
  return out.takeBytes().sublist(0, length);
}

/// HChaCha20 subkey derivation (draft-irtf-cfrg-xchacha §2.2):
/// 32-byte key + 16-byte nonce -> 32-byte subkey.
List<int> hchacha20(List<int> key, List<int> nonce16) {
  if (key.length != 32) {
    throw ArgumentError.value(key.length, 'key', 'harus 32 byte');
  }
  if (nonce16.length != 16) {
    throw ArgumentError.value(nonce16.length, 'nonce', 'harus 16 byte');
  }
  final state = List<int>.filled(16, 0);
  for (var i = 0; i < 4; i++) {
    state[i] = _chachaConstants[i];
  }
  for (var i = 0; i < 8; i++) {
    state[4 + i] = _load32(key, i * 4);
  }
  for (var i = 0; i < 4; i++) {
    state[12 + i] = _load32(nonce16, i * 4);
  }
  _rounds(state);
  final out = List<int>.filled(32, 0);
  for (var i = 0; i < 4; i++) {
    _store32(out, i * 4, state[i]);
    _store32(out, 16 + i * 4, state[12 + i]);
  }
  return out;
}

List<int> _pad16(List<int> b) {
  final rem = b.length % 16;
  return rem == 0 ? b : [...b, ...List<int>.filled(16 - rem, 0)];
}

List<int> _le64(int v) => [
      v & 0xff,
      (v >> 8) & 0xff,
      (v >> 16) & 0xff,
      (v >> 24) & 0xff,
      0,
      0,
      0,
      0,
    ];

List<int> _aeadMacData(List<int> aad, List<int> cipher) => [
      ..._pad16(aad),
      ..._pad16(cipher),
      ..._le64(aad.length),
      ..._le64(cipher.length),
    ];

bool _constantTimeEquals(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}

/// AEAD_CHACHA20_POLY1305 seal (RFC 8439 §2.8): returns ciphertext || tag(16).
List<int> aeadChaCha20Poly1305Seal(
  List<int> plaintext,
  List<int> nonce12,
  List<int> key, {
  List<int> aad = const [],
}) {
  if (key.length != 32) {
    throw ArgumentError.value(key.length, 'key', 'harus 32 byte');
  }
  if (nonce12.length != 12) {
    throw ArgumentError.value(nonce12.length, 'nonce', 'harus 12 byte');
  }
  final block0 = _chachaBlock(_stateFrom(key, nonce12, 0));
  final otk = block0.sublist(0, 32);
  final ks = _chacha20Stream(key, nonce12, plaintext.length, counter: 1);
  final cipher = [
    for (var i = 0; i < plaintext.length; i++) plaintext[i] ^ ks[i],
  ];
  final tag = naclPoly1305(_aeadMacData(aad, cipher), otk);
  return [...cipher, ...tag];
}

/// AEAD_CHACHA20_POLY1305 open: verifies the tag (constant time) then
/// decrypts. Throws ArgumentError on any tag mismatch.
List<int> aeadChaCha20Poly1305Open(
  List<int> sealed,
  List<int> nonce12,
  List<int> key, {
  List<int> aad = const [],
}) {
  if (key.length != 32) {
    throw ArgumentError.value(key.length, 'key', 'harus 32 byte');
  }
  if (nonce12.length != 12) {
    throw ArgumentError.value(nonce12.length, 'nonce', 'harus 12 byte');
  }
  if (sealed.length < 16) {
    throw ArgumentError('data terlalu pendek (min 16 byte tag)');
  }
  final cipher = sealed.sublist(0, sealed.length - 16);
  final tag = sealed.sublist(sealed.length - 16);
  final block0 = _chachaBlock(_stateFrom(key, nonce12, 0));
  final otk = block0.sublist(0, 32);
  final expected = naclPoly1305(_aeadMacData(aad, cipher), otk);
  if (!_constantTimeEquals(tag, expected)) {
    throw ArgumentError('tag Poly1305 tidak cocok (data rusak/diubah)');
  }
  final ks = _chacha20Stream(key, nonce12, cipher.length, counter: 1);
  return [for (var i = 0; i < cipher.length; i++) cipher[i] ^ ks[i]];
}

/// AEAD_XCHACHA20_POLY1305 seal (draft-irtf-cfrg-xchacha §2):
/// HChaCha20 subkey from nonce[0:16], then RFC 8439 AEAD with
/// nonce 00000000 || nonce[16:24]. Returns ciphertext || tag(16).
List<int> aeadXchacha20Poly1305Seal(
  List<int> plaintext,
  List<int> nonce24,
  List<int> key, {
  List<int> aad = const [],
}) {
  if (key.length != 32) {
    throw ArgumentError.value(key.length, 'key', 'harus 32 byte');
  }
  if (nonce24.length != 24) {
    throw ArgumentError.value(nonce24.length, 'nonce', 'harus 24 byte');
  }
  final subkey = hchacha20(key, nonce24.sublist(0, 16));
  final nonce12 = [0, 0, 0, 0, ...nonce24.sublist(16, 24)];
  return aeadChaCha20Poly1305Seal(plaintext, nonce12, subkey, aad: aad);
}

/// AEAD_XCHACHA20_POLY1305 open: verifies the tag then decrypts.
/// Throws ArgumentError on any tag mismatch.
List<int> aeadXchacha20Poly1305Open(
  List<int> sealed,
  List<int> nonce24,
  List<int> key, {
  List<int> aad = const [],
}) {
  if (key.length != 32) {
    throw ArgumentError.value(key.length, 'key', 'harus 32 byte');
  }
  if (nonce24.length != 24) {
    throw ArgumentError.value(nonce24.length, 'nonce', 'harus 24 byte');
  }
  final subkey = hchacha20(key, nonce24.sublist(0, 16));
  final nonce12 = [0, 0, 0, 0, ...nonce24.sublist(16, 24)];
  return aeadChaCha20Poly1305Open(sealed, nonce12, subkey, aad: aad);
}

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

class VaultRecoveryException implements Exception {
  VaultRecoveryException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Shamir secret sharing over GF(2^8) for the vault recovery key (SEC-06).
/// The vault key is split into [shares] share strings of which any
/// [threshold] reconstruct it; fewer shares reveal nothing about the key.
///
/// Share wire format (base64url): `version(1) | threshold(1) | x(1) |
/// checksum(4) | y(key.length)`. The 4-byte prefix of SHA-256(key) lets
/// [combineKey] reject a wrong or mismatched share set early; final
/// authenticity still comes from the AEAD when the key is used.
abstract final class VaultRecovery {
  static const formatVersion = 1;
  static const _checksumLength = 4;
  static const _maxShares = 255;

  /// Splits [key] into [shares] base64url share strings, [threshold] of
  /// which are needed by [combineKey].
  static List<String> splitKey(
    List<int> key, {
    required int shares,
    required int threshold,
  }) {
    final secret = Uint8List.fromList(key);
    if (secret.isEmpty) {
      throw ArgumentError('kunci kosong tidak bisa dipecah');
    }
    if (threshold < 2 || threshold > _maxShares) {
      throw ArgumentError('threshold harus 2..$_maxShares');
    }
    if (shares < threshold || shares > _maxShares) {
      throw ArgumentError('jumlah share harus >= threshold dan <= $_maxShares');
    }
    final checksum = Uint8List.fromList(
      sha256.convert(secret).bytes.sublist(0, _checksumLength),
    );
    final random = Random.secure();
    final coefficientCount = threshold - 1;
    final coefficients = List<Uint8List>.generate(secret.length, (_) {
      final row = Uint8List(coefficientCount);
      for (var k = 0; k < coefficientCount; k++) {
        row[k] = random.nextInt(256);
      }
      return row;
    });
    final result = <String>[];
    for (var index = 1; index <= shares; index++) {
      final y = Uint8List(secret.length);
      for (var b = 0; b < secret.length; b++) {
        var value = secret[b];
        var xPower = 1;
        for (var k = 0; k < coefficientCount; k++) {
          xPower = gfMul(xPower, index);
          value ^= gfMul(xPower, coefficients[b][k]);
        }
        y[b] = value & 0xFF;
      }
      final payload = BytesBuilder()
        ..addByte(formatVersion)
        ..addByte(threshold)
        ..addByte(index)
        ..add(checksum)
        ..add(y);
      result.add(base64Url.encode(payload.toBytes()));
    }
    return result;
  }

  /// Reconstructs the key from at least [threshold] share strings. Mismatched
  /// versions, thresholds, checksums, or duplicate share indices throw
  /// [VaultRecoveryException].
  static List<int> combineKey(List<String> shareStrings) {
    if (shareStrings.length < 2) {
      throw VaultRecoveryException('butuh minimal 2 share');
    }
    final parsed = [
      for (final share in shareStrings) _parseShare(share),
    ];
    final first = parsed.first;
    for (final share in parsed.skip(1)) {
      if (share.version != first.version) {
        throw VaultRecoveryException('versi format share berbeda');
      }
      if (share.threshold != first.threshold) {
        throw VaultRecoveryException('threshold share berbeda');
      }
      for (var k = 0; k < _checksumLength; k++) {
        if (share.checksum[k] != first.checksum[k]) {
          throw VaultRecoveryException(
            'share berasal dari kunci berbeda (checksum tidak cocok)',
          );
        }
      }
    }
    if (parsed.length < first.threshold) {
      throw VaultRecoveryException(
        'share tidak cukup: butuh ${first.threshold}, dapat ${parsed.length}',
      );
    }
    final distinct = {for (final share in parsed) share.x};
    if (distinct.length != parsed.length) {
      throw VaultRecoveryException('ada share duplikat (x sama)');
    }
    final length = parsed.first.y.length;
    final key = Uint8List(length);
    for (var b = 0; b < length; b++) {
      var value = 0;
      for (var j = 0; j < parsed.length; j++) {
        var weight = 1;
        for (var m = 0; m < parsed.length; m++) {
          if (m == j) continue;
          weight = gfMul(weight, gfDiv(parsed[m].x, parsed[m].x ^ parsed[j].x));
        }
        value ^= gfMul(parsed[j].y[b], weight);
      }
      key[b] = value & 0xFF;
    }
    final checksum = sha256.convert(key).bytes.sublist(0, _checksumLength);
    for (var k = 0; k < _checksumLength; k++) {
      if (checksum[k] != first.checksum[k]) {
        throw VaultRecoveryException(
          'kombinasi share menghasilkan kunci salah (checksum tidak cocok)',
        );
      }
    }
    return key;
  }

  static _Share _parseShare(String share) {
    late Uint8List bytes;
    try {
      bytes = base64Url.decode(share.trim());
    } on FormatException {
      throw VaultRecoveryException('share bukan base64url valid');
    }
    if (bytes.length < 7) {
      throw VaultRecoveryException('share terlalu pendek');
    }
    if (bytes[0] != formatVersion) {
      throw VaultRecoveryException('versi format share tidak dikenal: ${bytes[0]}');
    }
    return _Share(
      version: bytes[0],
      threshold: bytes[1],
      x: bytes[2],
      checksum: Uint8List.sublistView(bytes, 3, 3 + _checksumLength),
      y: Uint8List.sublistView(bytes, 3 + _checksumLength),
    );
  }
}

class _Share {
  const _Share({
    required this.version,
    required this.threshold,
    required this.x,
    required this.checksum,
    required this.y,
  });

  final int version;
  final int threshold;
  final int x;
  final Uint8List checksum;
  final Uint8List y;
}

const int _gfPoly = 0x11b;
final Uint8List _gfExp = Uint8List(512);
final Uint8List _gfLog = Uint8List(256);
var _gfReady = false;

void _gfInit() {
  if (_gfReady) return;
  var value = 1;
  for (var i = 0; i < 255; i++) {
    _gfExp[i] = value;
    _gfLog[value] = i;
    value = _gfMulRaw(value, 3);
  }
  for (var i = 255; i < 512; i++) {
    _gfExp[i] = _gfExp[i - 255];
  }
  _gfReady = true;
}

int _gfMulRaw(int a, int b) {
  var result = 0;
  while (b > 0) {
    if (b & 1 == 1) result ^= a;
    b >>= 1;
    a <<= 1;
    if (a & 0x100 != 0) a ^= _gfPoly;
  }
  return result & 0xFF;
}

/// Multiplication in GF(2^8) with the AES reduction polynomial.
int gfMul(int a, int b) {
  _gfInit();
  if (a == 0 || b == 0) return 0;
  return _gfExp[_gfLog[a] + _gfLog[b]];
}

/// Division in GF(2^8); dividing by zero throws [ArgumentError].
int gfDiv(int a, int b) {
  _gfInit();
  if (b == 0) throw ArgumentError('pembagian nol di GF(2^8)');
  if (a == 0) return 0;
  return _gfExp[(255 + _gfLog[a] - _gfLog[b]) % 255];
}

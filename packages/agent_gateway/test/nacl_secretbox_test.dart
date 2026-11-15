import 'package:agent_gateway/agent_gateway.dart';
import 'package:test/test.dart';

List<int> _hex(String s) => [
      for (var i = 0; i < s.length; i += 2)
        int.parse(s.substring(i, i + 2), radix: 16),
    ];

String _toHex(List<int> b) =>
    b.map((e) => e.toRadixString(16).padLeft(2, '0')).join();

void main() {
  group('Poly1305 (RFC 8439 2.5.2)', () {
    test('official known-answer vector', () {
      final key = _hex(
        '85d6be7857556d337f4452fe42d506a8'
        '0103808afb0db2fd4abff6af4149f51b',
      );
      final tag = naclPoly1305(
        'Cryptographic Forum Research Group'.codeUnits,
        key,
      );
      expect(_toHex(tag), 'a8061dc1305136c6c22b8baf0c0127a9');
    });
  });

  group('secretbox (XSalsa20-Poly1305)', () {
    final key = List<int>.generate(32, (i) => i);
    final nonce = List<int>.generate(24, (i) => i);

    test('regression anchor for a short message', () {
      // Cross-implementation anchor, NOT a libsodium known-answer vector.
      // Produced by an independent spec-based reference (quarterround
      // formulation) that agreed with this port on 200 random Salsa20
      // states. Replace with libsodium crypto_secretbox output when
      // available; until then this pins behaviour against refactors.
      final box = naclSecretbox(_hex('0001020304'), nonce, key);
      expect(_toHex(box), '0e4ecd8518e11f401696a1b9fcf4d3395efe3a4cc3');
    });

    test('roundtrip across block boundaries', () {
      const lengths = <int>[
        0, 1, 15, 16, 17, 31, 32, 63, 64, 65, 127, 128, 1000,
      ];
      for (final length in lengths) {
        final message = List<int>.generate(length, (i) => (i * 7) % 256);
        final box = naclSecretbox(message, nonce, key);
        expect(box.length, length + 16, reason: 'length $length');
        expect(
          naclSecretboxOpen(box, nonce, key),
          message,
          reason: 'length $length',
        );
      }
    });

    test('tampered tag is rejected', () {
      final box = naclSecretbox([1, 2, 3], nonce, key);
      final bad = [...box]..[0] ^= 0x01;
      expect(() => naclSecretboxOpen(bad, nonce, key), throwsArgumentError);
    });

    test('tampered ciphertext is rejected', () {
      final box = naclSecretbox([1, 2, 3], nonce, key);
      final bad = [...box]..[16] ^= 0x01;
      expect(() => naclSecretboxOpen(bad, nonce, key), throwsArgumentError);
    });

    test('wrong key is rejected', () {
      final box = naclSecretbox([1, 2, 3], nonce, key);
      final other = List<int>.generate(32, (i) => i + 1);
      expect(() => naclSecretboxOpen(box, nonce, other), throwsArgumentError);
    });

    test('wrong nonce is rejected', () {
      final box = naclSecretbox([1, 2, 3], nonce, key);
      final other = List<int>.generate(24, (i) => i + 1);
      expect(() => naclSecretboxOpen(box, other, key), throwsArgumentError);
    });

    test('rejects malformed key, nonce and box', () {
      expect(
        () => naclSecretbox([1], List<int>.filled(23, 0), key),
        throwsArgumentError,
      );
      expect(
        () => naclSecretbox([1], nonce, List<int>.filled(31, 0)),
        throwsArgumentError,
      );
      expect(
        () => naclSecretboxOpen(List<int>.filled(15, 0), nonce, key),
        throwsArgumentError,
      );
    });

    test('every nonce byte affects the box', () {
      final message = [9, 9, 9];
      final base = naclSecretbox(message, nonce, key);
      final head = [...nonce]..[0] ^= 0x01;
      final tail = [...nonce]..[23] ^= 0x01;
      expect(naclSecretbox(message, head, key), isNot(base));
      expect(naclSecretbox(message, tail, key), isNot(base));
    });
  });
}

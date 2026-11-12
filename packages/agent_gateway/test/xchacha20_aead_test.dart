import 'package:agent_gateway/agent_gateway.dart';
import 'package:test/test.dart';

List<int> _hex(String s) => [
      for (var i = 0; i < s.length; i += 2) int.parse(s.substring(i, i + 2), radix: 16),
    ];

String _toHex(List<int> b) =>
    b.map((e) => e.toRadixString(16).padLeft(2, '0')).join();

final _rfcPlaintext =
    'Ladies and Gentlemen of the class of \'99: If I could offer you '
    'only one tip for the future, sunscreen would be it.';

void main() {
  group('HChaCha20 (draft-irtf-cfrg-xchacha §2.2.1)', () {
    test('official test vector', () {
      final subkey = hchacha20(
        _hex('000102030405060708090a0b0c0d0e0f'
            '101112131415161718191a1b1c1d1e1f'),
        _hex('000000090000004a0000000031415927'),
      );
      expect(
        _toHex(subkey),
        '82413b4227b27bfed30e42508a877d73'
        'a0f9e4d58a74a853c12ec41326d3ecdc',
      );
    });
  });

  group('AEAD_CHACHA20_POLY1305 (RFC 8439 §2.8.2 composition)', () {
    test('XChaCha AEAD official vector (draft §A.3.1)', () {
      final key = _hex(
          '808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f');
      final nonce = _hex('404142434445464748494a4b4c4d4e4f5051525354555657');
      final aad = _hex('50515253c0c1c2c3c4c5c6c7');
      final pt = _rfcPlaintext.codeUnits;

      final sealed = aeadXchacha20Poly1305Seal(pt, nonce, key, aad: aad);
      final cipher = sealed.sublist(0, sealed.length - 16);
      final tag = sealed.sublist(sealed.length - 16);
      expect(_toHex(cipher),
          'bd6d179d3e83d43b9576579493c0e939'
          '572a1700252bfaccbed2902c21396cbb'
          '731c7f1b0b4aa6440bf3a82f4eda7e39'
          'ae64c6708c54c216cb96b72e1213b452'
          '2f8c9ba40db5d945b11b69b982c1bb9e'
          '3f3fac2bc369488f76b2383565d3fff9'
          '21f9664c97637da9768812f615c68b13'
          'b52e');
      expect(_toHex(tag), 'c0875924c1c7987947deafd8780acf49');

      final opened = aeadXchacha20Poly1305Open(sealed, nonce, key, aad: aad);
      expect(opened, pt);
    });

    test('tampered ciphertext is rejected', () {
      final key = _hex(
          '808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f');
      final nonce = _hex('404142434445464748494a4b4c4d4e4f5051525354555657');
      final sealed = aeadXchacha20Poly1305Seal([1, 2, 3], nonce, key);
      final tampered = [...sealed]..[0] ^= 0x01;
      expect(
        () => aeadXchacha20Poly1305Open(tampered, nonce, key),
        throwsArgumentError,
      );
    });

    test('tampered AAD is rejected', () {
      final key = _hex(
          '808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f');
      final nonce = _hex('404142434445464748494a4b4c4d4e4f5051525354555657');
      final sealed = aeadXchacha20Poly1305Seal([1, 2, 3], nonce, key,
          aad: [0xAA, 0xBB]);
      expect(
        () => aeadXchacha20Poly1305Open(sealed, nonce, key, aad: [0xAA, 0xBC]),
        throwsArgumentError,
      );
    });

    test('roundtrip with empty plaintext and aad', () {
      final key = List<int>.generate(32, (i) => i);
      final nonce = List<int>.generate(24, (i) => i * 3 & 0xff);
      final sealed = aeadXchacha20Poly1305Seal(const [], nonce, key);
      expect(sealed.length, 16);
      expect(aeadXchacha20Poly1305Open(sealed, nonce, key), isEmpty);
    });
  });

  group('AeadXchacha20Poly1305Encryptor (voice mode)', () {
    test('advertises the aead_xchacha20_poly1305 mode', () {
      expect(
        const AeadXchacha20Poly1305Encryptor().mode,
        'aead_xchacha20_poly1305',
      );
    });

    test('seals with the RTP header as AAD; roundtrip via open', () {
      const encryptor = AeadXchacha20Poly1305Encryptor();
      final secretKey = List<int>.generate(32, (i) => 0x20 + i);
      final header = [
        0x80, 0x78, 0x00, 0x01, 0x00, 0x00, 0x10, 0x00, 0x00, 0x00, 0x00, 0x01,
      ];
      final nonce = [...header, ...List<int>.filled(12, 0)];
      final frame = List<int>.generate(512, (i) => i & 0xff);

      final sealed = encryptor.encrypt(frame, nonce, secretKey);
      expect(sealed.length, frame.length + 16);

      final opened = aeadXchacha20Poly1305Open(
        sealed,
        nonce,
        secretKey,
        aad: header,
      );
      expect(opened, frame);
    });

    test('rejects invalid key and nonce sizes', () {
      const encryptor = AeadXchacha20Poly1305Encryptor();
      final nonce = List<int>.filled(24, 0);
      expect(
        () => encryptor.encrypt([1], nonce, List<int>.filled(16, 0)),
        throwsStateError,
      );
      expect(
        () => encryptor.encrypt([1], List<int>.filled(12, 0),
            List<int>.filled(32, 0)),
        throwsStateError,
      );
    });
  });
}

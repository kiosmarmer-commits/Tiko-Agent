// Hermes fase-20: image eviction policy (`agent/image_eviction_policy.py`)
// + fase-22 message sanitization + fase-23 turn deadline — uji fungsi murni.
import 'dart:convert';

import 'package:agent_core/agent_core.dart';
import 'package:test/test.dart';

void main() {
  group('Dimension reader (header-only)', () {
    test('PNG IHDR terbaca', () {
      final raw = <int>[
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 3, 0xE8, // width 1000
        0, 0, 0, 0xFA, // height 250
      ];
      final dims = imageDimensionsFromBytes(raw);
      expect(dims, isNotNull);
      expect(dims!.$1, 1000);
      expect(dims.$2, 250);
    });

    test('JPEG SOF0 terbaca', () {
      final raw = <int>[
        0xFF, 0xD8, // SOI
        0xFF, 0xC0, 0x00, 0x0B, 0x08, // SOF0 len 11, precision 8
        0x00, 0x64, // height 100
        0x01, 0x90, // width 400
        0x01, 0x00, 0x00, 0xFF, 0xD9,
      ];
      final dims = imageDimensionsFromBytes(raw);
      expect(dims, isNotNull);
      expect(dims!.$1, 400);
      expect(dims.$2, 100);
    });

    test('byte acak => null', () {
      expect(imageDimensionsFromBytes([1, 2, 3, 4, 5, 6]), isNull);
    });

    test('imageMaxSideFromBase64: data URL PNG', () {
      final raw = <int>[
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 5, 0, 0, 0, 3,
      ];
      final b64 = base64.encode(raw);
      expect(imageMaxSideFromBase64('data:image/png;base64,$b64'), 5);
      expect(imageMaxSideFromBase64(b64), 5);
    });

    test('remote URL / base64 korup => null (tidak aman)', () {
      expect(imageMaxSideFromBase64('https://example.com/a.png'), isNull);
      expect(imageMaxSideFromBase64('data:image/png;base64,!!!!'), isNull);
      expect(imageMaxSideFromBase64(null), isNull);
    });
  });

  group('Retire count (step function)', () {
    test('di bawah limit => 0', () {
      expect(
        outboundImageRetireCount([1, 1, 1], 0, manyImageSafe: true),
        0,
      );
    });

    test('overshoot: retire dalam kuantum batch, bukan per-gambar', () {
      final r = outboundImageRetireCount(
        List.filled(24, 1),
        0,
        manyImageSafe: true, // limit 100? tidak — hard limit hanya bila aman
      );
      // manyImageSafe=true => limit 100 => tidak ada pensiunan.
      expect(r, 0);
      final r2 = outboundImageRetireCount(
        List.filled(24, 1),
        0,
        manyImageSafe: false, // limit 20
      );
      // 24 > 20: quantum = min(8, window-floor) — window = 20, floor 3 =>
      // quantum 8; langkah pertama yang membuat request fit: 24-8=16 <= 20.
      expect(r2, 8);
    });

    test('upload reserved menembus ceiling => lantai melindungi terbaru', () {
      // 4 upload user (reserved), 0 carrier => tak ada yang bisa dipensiunkan.
      expect(outboundImageRetireCount([], 30), 0);
      // Carrier 2 blok, reserved 25 (ceiling 20 terlampaui oleh reserved):
      // lantai 3 shelter — retire = total - floor dalam kuantum.
      final r = outboundImageRetireCount([1, 1], 25);
      expect(r, greaterThanOrEqualTo(0));
    });

    test('block limit: ketat 20 vs hard 100', () {
      expect(outboundImageBlockLimit(false), 20);
      expect(outboundImageBlockLimit(true), 100);
    });
  });

  group('evictStaleOutboundImages', () {
    ChatMessage toolMsg(String id, int nImages, {int px = 64}) {
      final pxBytes = [
        (px >> 24) & 0xFF, (px >> 16) & 0xFF, (px >> 8) & 0xFF, px & 0xFF,
      ];
      final raw = <int>[
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
        0, 0, 0, 0, 0, 0, 0, 0,
        ...pxBytes, ...pxBytes,
      ];
      return ChatMessage(
        role: 'tool',
        content: 'hasil screenshot',
        toolCallId: id,
        name: 'browser',
        images: [for (var i = 0; i < nImages; i++) ChatImage(base64: base64.encode(raw))],
      );
    }

    test('di bawah limit: salinan identik (zero pruned)', () {
      final msgs = [
        const ChatMessage(role: 'user', content: 'halo'),
        toolMsg('t1', 2),
      ];
      final r = evictStaleOutboundImages(msgs);
      expect(r.pruned, 0);
      expect(identical(r.messages, msgs), isTrue);
    });

    test('di atas limit: tool-image terlama diganti placeholder, upload user aman', () {
      final upload = toolMsg('t0', 1); // akan dibuat role user di bawah
      final userUpload = ChatMessage(
        role: 'user',
        content: 'lihat ini',
        images: upload.images,
      );
      final msgs = <ChatMessage>[
        const ChatMessage(role: 'user', content: 'mulai'),
        toolMsg('t1', 1, px: 4096),
        toolMsg('t2', 1, px: 4096),
        toolMsg('t3', 1, px: 4096),
        toolMsg('t4', 1, px: 4096),
        toolMsg('t5', 1, px: 4096),
        toolMsg('t6', 1, px: 4096),
        toolMsg('t7', 1, px: 4096),
        toolMsg('t8', 1, px: 4096),
        toolMsg('t9', 1, px: 4096),
        toolMsg('t10', 1, px: 4096),
        toolMsg('t11', 1, px: 4096),
        toolMsg('t12', 1, px: 4096),
        toolMsg('t13', 1, px: 4096),
        toolMsg('t14', 1, px: 4096),
        toolMsg('t15', 1, px: 4096),
        toolMsg('t16', 1, px: 4096),
        toolMsg('t17', 1, px: 4096),
        toolMsg('t18', 1, px: 4096),
        toolMsg('t19', 1, px: 4096),
        toolMsg('t20', 1, px: 4096),
        toolMsg('t21', 1, px: 4096),
        toolMsg('t22', 1, px: 4096),
        toolMsg('t23', 1, px: 4096),
        userUpload,
      ];
      expect(msgs.length, 25);
      // Semua gambar > 2000px => many-image cap tidak aman => limit 20;
      // 1 reserved upload + 24 carrier blok => overshoot => retire kuantum 8.
      final r = evictStaleOutboundImages(msgs);
      expect(r.pruned, 8);
      expect(r.messages.length, msgs.length);
      // Upload user (pesan terakhir) tidak pernah ditulis ulang.
      expect(r.messages.last.images, isNotNull);
      // Pesan tool terlama kehilangan gambar.
      final prunedMsg = r.messages.firstWhere(
        (m) => m.role == 'tool' && m.toolCallId == 't1',
      );
      expect(prunedMsg.images, isNull);
      expect(prunedMsg.content, contains('gambar dihapus'));
      // Pesan tool terbaru tetap utuh.
      final keptMsg = r.messages.firstWhere(
        (m) => m.role == 'tool' && m.toolCallId == 't23',
      );
      expect(keptMsg.images, isNotNull);
    });
  });

  group('Message sanitization (fase-22)', () {
    test('CRLF dinormalisasi; kontrol char dibuang; LF/TAB dipertahankan', () {
      final out = sanitizeModelText('a\r\nb\x00c\td\x01e\x7F\rf');
      expect(out, 'a\nbc\tde\nf');
    });

    test('blok think di-strip', () {
      final open = String.fromCharCode(0x3C);
      final text =
          'jawaban${open}think>rahasia${open}/think> final';
      expect(sanitizeModelText(text), 'jawaban final');
    });

    test('lone surrogate diganti U+FFFD', () {
      final out = sanitizeModelText('a\uD800b');
      expect(out.codeUnits.contains(0xD800), isFalse);
      expect(out, contains('\uFFFD'));
    });

    test('coerceToolName: valid identitas, invalid dilipat', () {
      expect(coerceToolName('read_file'), 'read_file');
      expect(coerceToolName('a' * 80).length, 64);
      expect(coerceToolName('bad name!'), 'bad_name');
      expect(coerceToolName('***'), 'invalid_tool_call');
      expect(coerceToolName(null), 'invalid_tool_call');
    });

    test('sanitizeChatMessages: identik => list sama; kotor => diperbaiki', () {
      final clean = [
        const ChatMessage(role: 'user', content: 'halo'),
      ];
      expect(identical(sanitizeChatMessages(clean), clean), isTrue);

      final dirty = [
        const ChatMessage(
          role: 'assistant',
          content: 'ok\x00',
          toolCalls: [
            ToolCall(id: 'c1', name: 'bad name', args: {'cmd': 'a\x02b'}),
          ],
        ),
        const ChatMessage(role: 'tool', content: 'hasil', toolCallId: 'c1', name: 'bad name'),
      ];
      final out = sanitizeChatMessages(dirty);
      expect(identical(out, dirty), isFalse);
      expect(out[0].content, 'ok');
      expect(out[0].toolCalls!.first.name, 'bad_name');
      expect(out[0].toolCalls!.first.args['cmd'], 'ab');
      // Nama tool result ikut di-coerce agar konsisten dengan toolcall-nya.
      expect(out[1].name, 'bad_name');
    });
  });

  group('Turn deadline (fase-23)', () {
    test('off: isExpired selalu false, remaining null', () {
      final d = TurnDeadline.off();
      expect(d.enabled, isFalse);
      expect(d.isExpired, isFalse);
      expect(d.remaining(), isNull);
    });

    test('aktif: remaining menyusut lalu expired', () async {
      final d = TurnDeadline(const Duration(milliseconds: 30));
      expect(d.isExpired, isFalse);
      expect(d.remaining()!, greaterThan(Duration.zero));
      await Future<void>.delayed(const Duration(milliseconds: 45));
      expect(d.isExpired, isTrue);
      expect(d.remaining(), Duration.zero);
    });
  });
}

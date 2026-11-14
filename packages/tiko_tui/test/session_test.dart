import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tiko_tui/tiko_tui.dart';

void main() {
  group('TuiSession (line mode)', () {
    test('banner, handler dan exit', () async {
      final out = StringBuffer();
      final inputs = <String>[];
      final session = TuiSession(
        handler: (input) async {
          if (input == '/quit') return const TuiOutcome([], exit: true);
          inputs.add(input);
          return TuiOutcome(['balasan: $input']);
        },
        banner: ['Tiko TUI'],
        prompt: 'you> ',
        out: out,
        scriptedLines: ['halo', '/quit'],
      );
      await session.run();
      expect(inputs, ['halo']);
      expect(out.toString(), contains('Tiko TUI'));
      expect(out.toString(), contains('balasan: halo'));
      expect(out.toString(), contains('/quit'));
    });

    test('EOF mengakhiri sesi tanpa exit outcome', () async {
      final session = TuiSession(
        handler: (_) async => const TuiOutcome([]),
        out: StringBuffer(),
        scriptedLines: ['satu'],
      );
      await session.run();
    });

    test('multiline /begin..end dikirim sebagai satu input', () async {
      final inputs = <String>[];
      final session = TuiSession(
        handler: (input) async {
          if (input == '/quit') return const TuiOutcome([], exit: true);
          inputs.add(input);
          return const TuiOutcome(['ok']);
        },
        out: StringBuffer(),
        scriptedLines: ['/begin', 'baris satu', 'baris dua', '/end', '/quit'],
      );
      await session.run();
      expect(inputs, ['baris satu\nbaris dua']);
    });

    test('backslash melanjutkan baris', () async {
      final inputs = <String>[];
      final session = TuiSession(
        handler: (input) async {
          inputs.add(input);
          return const TuiOutcome(['ok']);
        },
        out: StringBuffer(),
        scriptedLines: ['satu \\', 'dua'],
      );
      await session.run();
      expect(inputs, ['satu \ndua']);
    });

    test('clear menulis escape ANSI clear screen', () async {
      final out = StringBuffer();
      final session = TuiSession(
        handler: (_) async => const TuiOutcome(['x'], clear: true),
        out: out,
        scriptedLines: ['c'],
      );
      await session.run();
      expect(out.toString(), contains('\x1B[2J\x1B[H'));
    });

    test('riwayat dimuat dan disimpan via historyStore', () async {
      final dir = await Directory.systemTemp.createTemp('tiko-session');
      addTearDown(() => dir.delete(recursive: true));
      final path = '${dir.path}/hist.txt';
      File(path).writeAsStringSync('lama\n');

      final session = TuiSession(
        handler: (input) async {
          expect(input, 'baru');
          return const TuiOutcome(['ok']);
        },
        historyStore: TuiHistoryStore(path),
        out: StringBuffer(),
        scriptedLines: ['baru'],
      );
      await session.run();
      expect(session.history, containsAll(['lama', 'baru']));
      expect(File(path).readAsStringSync(), 'lama\nbaru\n');
    });
  });

  group('TuiSession (raw mode via inputStream)', () {
    Stream<List<int>> bytes(List<List<int>> chunks) async* {
      for (final chunk in chunks) {
        yield chunk;
      }
    }

    test('input mentah dengan Enter memicu handler', () async {
      final inputs = <String>[];
      final out = StringBuffer();
      final session = TuiSession(
        handler: (input) async {
          inputs.add(input);
          return const TuiOutcome(['respon']);
        },
        prompt: 'you> ',
        out: out,
        inputStream: bytes([utf8.encode('hai'), [0x0D], [0x04]]),
      );
      await session.run();
      expect(inputs, ['hai']);
      expect(out.toString(), contains('respon'));
    });

    test('panah atas menarik riwayat lalu Enter mengirim ulang', () async {
      final inputs = <String>[];
      final session = TuiSession(
        handler: (input) async {
          inputs.add(input);
          return const TuiOutcome(['ok']);
        },
        out: StringBuffer(),
        history: ['perintah-lama'],
        inputStream: bytes([
          [0x1B, 0x5B, 0x41],
          [0x0D],
          [0x04],
        ]),
      );
      await session.run();
      expect(inputs, ['perintah-lama']);
    });
  });
}

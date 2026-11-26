import 'dart:async';
import 'dart:convert';

import 'package:test/test.dart';
import 'package:tiko_tui/tiko_tui.dart';

void main() {
  group('SlashCommandRegistry', () {
    test('builtin berisi perintah inti dan tersortir', () {
      final reg = SlashCommandRegistry();
      expect(reg.find('help'), isNotNull);
      expect(reg.find('HELP')!.name, 'help');
      expect(reg.find('tidakada'), isNull);
    });

    test('register menimpa perintah nama sama dan menjaga urutan', () {
      final reg = SlashCommandRegistry();
      reg.register(const SlashCommand(name: 'deploy', description: 'x'));
      reg.register(const SlashCommand(name: 'deploy', description: 'y'));
      expect(reg.commands.where((c) => c.name == 'deploy').length, 1);
      final names = reg.commands.map((c) => c.name).toList();
      expect(names, equals([...names]..sort()));
    });

    test('fuzzy subsequence: /hk cocok /help, bukan /exit', () {
      expect(SlashCommandRegistry.fuzzyMatch('hl', 'help'), isNotNull);
      expect(SlashCommandRegistry.fuzzyMatch('hk', 'exit'), isNull);
      expect(SlashCommandRegistry.fuzzyMatch('h', 'help'), 0);
      expect(SlashCommandRegistry.fuzzyMatch('sess', 'session'), 0);
      expect(SlashCommandRegistry.fuzzyMatch('ssn', 'session'), isNotNull);
    });

    test('completions: query kosong mengembalikan semua', () {
      final reg = SlashCommandRegistry();
      final c = reg.completions('/', '/');
      expect(c, contains('/help'));
      expect(c, contains('/skills'));
    });

    test('completions fuzzy: token hm → /history', () {
      final reg = SlashCommandRegistry();
      expect(reg.completions('/', '/hstry'), contains('/history'));
      expect(reg.completions('/', '/hstry'), isNot(contains('/exit')));
    });

    test('completions hanya aktif di prefix slash', () {
      final reg = SlashCommandRegistry();
      expect(reg.completions('halo ', 'hi'), isEmpty);
    });

    test('integrasi LineEditor: Tab meng-complete slash command', () {
      final reg = SlashCommandRegistry();
      final editor = LineEditor(
        completer: (prefix, token) => reg.completions(prefix, token),
      );
      for (final ch in '/me'.split('')) {
        editor.insert(ch);
      }
      final candidates = editor.complete();
      expect(candidates, isNotEmpty);
      expect(candidates.join(' '), contains('/memory'));
    });
  });

  group('ToolTraceRenderer', () {
    test('start lalu end menghasilkan pasangan baris berurutan', () {
      final r = ToolTraceRenderer()..color = false;
      r.onCall('shell', {'cmd': 'ls -la'});
      r.onResult('shell', isError: false, durationMs: 123, args: {'cmd': 'ls'});
      final lines = r.render();
      expect(lines.length, 2);
      expect(lines[0], contains('[tool] shell'));
      expect(lines[0], contains('cmd=ls -la'));
      expect(lines[1], contains('[✓ tool] shell'));
      expect(lines[1], contains('123ms'));
      expect(lines[1], isNot(contains('✗')));
    });

    test('error tool ditandai ✗', () {
      final r = ToolTraceRenderer()..color = false;
      r.onCall('shell', {'cmd': 'false'});
      r.onResult('shell', isError: true, durationMs: 5);
      expect(r.render().last, contains('✗'));
    });

    test('argumen dipangkas dan newline dibungkus satu baris', () {
      final r = ToolTraceRenderer(argsPreviewChars: 20)..color = false;
      r.onCall('write_file', {
        'path': 'a/b/c.txt',
        'content': 'baris1\nbaris2 panjang sekali melebihi batas karakter',
      });
      final line = r.render().single;
      expect(line.contains('\n'), isFalse);
      expect(line, contains('…'));
    });

    test('kapasitas maxEvents membuang event tertua', () {
      final r = ToolTraceRenderer(maxEvents: 4)..color = false;
      for (var i = 0; i < 10; i++) {
        r.onCall('t$i', const {});
      }
      expect(r.length, 4);
      final lines = r.render().join('\n');
      expect(lines, contains('t9'));
      expect(lines, isNot(contains('t0')));
    });
  });

  group('Interrupt-and-redirect', () {
    List<int> bytesOf(String s) => utf8.encode(s);

    test('ketikan saat turn diarahkan ke prompt berikutnya', () async {
      final out = StringBuffer();
      final handled = <String>[];
      final controller = StreamController<List<int>>();
      final session = TuiSession(
        handler: (input) async {
          handled.add(input);
          if (input == 'kerja') {
            controller.add(bytesOf('ketik'));
            await Future<void>.delayed(const Duration(milliseconds: 200));
            controller.add(bytesOf('\x03'));
            await Future<void>.delayed(const Duration(milliseconds: 200));
          }
          return const TuiOutcome(['ok']);
        },
        inputStream: controller.stream,
        out: out,
      );
      final running = session.run();
      controller.add(bytesOf('kerja\r'));
      await Future<void>.delayed(const Duration(milliseconds: 900));
      controller.add(bytesOf('\r'));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await controller.close();
      await running;

      expect(handled, contains('kerja'));
      expect(handled, contains('ketik'),
          reason: 'ketikan saat turn harus muncul di prompt berikutnya');
      expect(out.toString(), contains('dibatalkan'));
    });
  });
}

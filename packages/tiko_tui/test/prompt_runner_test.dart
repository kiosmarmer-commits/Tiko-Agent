import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tiko_tui/tiko_tui.dart';

void main() {
  group('PromptRunner (line mode)', () {
    test('prompt mengembalikan default saat input kosong', () async {
      final out = StringBuffer();
      final runner = PromptRunner(
        scriptedLines: [''],
        out: out,
        forceLineMode: true,
      );
      final value = await runner.prompt('Host', def: 'http://localhost');
      expect(value, 'http://localhost');
      expect(out.toString(), contains('Host [http://localhost]:'));
    });

    test('prompt required mengulang sampai terisi', () async {
      final out = StringBuffer();
      final runner = PromptRunner(
        scriptedLines: ['', '', 'ollama_native'],
        out: out,
        forceLineMode: true,
      );
      final value = await runner.prompt('Provider', required: true);
      expect(value, 'ollama_native');
      expect(out.toString(), contains('Wajib diisi.'));
    });

    test('prompt tanpa required mengembalikan string kosong', () async {
      final runner = PromptRunner(
        scriptedLines: [''],
        out: StringBuffer(),
        forceLineMode: true,
      );
      expect(await runner.prompt('Opsional'), '');
    });

    test('confirm hanya menerima varian ya', () async {
      Future<bool> run(String line) async {
        final runner = PromptRunner(
          scriptedLines: [line],
          out: StringBuffer(),
          forceLineMode: true,
        );
        return runner.confirm('Lanjut?');
      }

      expect(await run('y'), isTrue);
      expect(await run('Ya'), isTrue);
      expect(await run('YES'), isTrue);
      expect(await run('n'), isFalse);
      expect(await run(''), isFalse);
      expect(await run('oke'), isFalse);
    });

    test('readLine mencatat riwayat non-kosong dan trim', () async {
      final runner = PromptRunner(
        scriptedLines: ['  halo  ', ''],
        out: StringBuffer(),
        forceLineMode: true,
      );
      expect(await runner.readLine('label: '), '  halo  ');
      expect(await runner.readLine('label: '), '');
      expect(runner.history, ['halo']);
    });

    test('PromptAborted saat skrip habis', () async {
      final runner = PromptRunner(
        scriptedLines: ['satu'],
        out: StringBuffer(),
        forceLineMode: true,
      );
      await runner.readLine('a: ');
      await expectLater(
        runner.readLine('b: '),
        throwsA(isA<PromptAborted>()),
      );
    });

    test('saveHistory menulis lewat historyStore', () async {
      final dir = await Directory.systemTemp.createTemp('tiko-prompt');
      addTearDown(() => dir.delete(recursive: true));
      final path = '${dir.path}/hist.txt';
      final runner = PromptRunner(
        scriptedLines: ['mock'],
        out: StringBuffer(),
        forceLineMode: true,
        historyStore: TuiHistoryStore(path),
      );
      await runner.readLine('p: ');
      await runner.saveHistory();
      expect(File(path).readAsStringSync(), 'mock\n');
    });
  });

  group('PromptRunner (raw mode via inputStream)', () {
    Stream<List<int>> bytes(List<List<int>> chunks) async* {
      for (final chunk in chunks) {
        yield chunk;
      }
    }

    test('mengetik lalu Enter mengirim baris', () async {
      final out = StringBuffer();
      final runner = PromptRunner(
        inputStream: bytes([utf8.encode('halo'), [0x0D]]),
        out: out,
      );
      final line = await runner.readLine('you> ');
      expect(line, 'halo');
      expect(out.toString(), startsWith('you> '));
      expect(runner.history, ['halo']);
    });

    test('backspace menghapus karakter', () async {
      final runner = PromptRunner(
        inputStream: bytes([
          utf8.encode('helo'),
          [0x7F],
          utf8.encode('lo'),
          [0x0D],
        ]),
        out: StringBuffer(),
      );
      expect(await runner.readLine('> '), 'hello');
    });

    test('Tab menyelesaikan token tunggal', () async {
      final runner = PromptRunner(
        inputStream: bytes([
          utf8.encode('oll'),
          [0x09],
          [0x0D],
        ]),
        out: StringBuffer(),
      );
      final line = await runner.readLine(
        'p: ',
        completions: ['mock', 'ollama_native', 'openai'],
      );
      expect(line, 'ollama_native');
    });

    test('Ctrl+C melempar PromptAborted', () async {
      final runner = PromptRunner(
        inputStream: bytes([[0x03]]),
        out: StringBuffer(),
      );
      await expectLater(
        runner.readLine('x: '),
        throwsA(isA<PromptAborted>()),
      );
    });

    test('Ctrl+D pada buffer kosong melempar PromptAborted', () async {
      final runner = PromptRunner(
        inputStream: bytes([[0x04]]),
        out: StringBuffer(),
      );
      await expectLater(
        runner.readLine('x: '),
        throwsA(isA<PromptAborted>()),
      );
    });
  });
}

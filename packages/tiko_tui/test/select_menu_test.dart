import 'dart:convert';

import 'package:test/test.dart';
import 'package:tiko_tui/tiko_tui.dart';

List<int> _bytes(String s) => utf8.encode(s);

void main() {
  group('PromptRunner.select (line/scripted mode)', () {
    test('kosong memilih default', () async {
      final out = StringBuffer();
      final runner = PromptRunner(
        scriptedLines: [''],
        out: out,
        forceLineMode: true,
      );
      final picked = await runner.select(
        'Tipe provider:',
        ['mock', 'ollama_native', 'gemini'],
        def: 'ollama_native',
      );
      expect(picked, 'ollama_native');
      expect(out.toString(), contains('1. mock'));
      expect(out.toString(), contains('2. ollama_native (default)'));
    });

    test('memilih lewat angka', () async {
      final runner = PromptRunner(
        scriptedLines: ['3'],
        out: StringBuffer(),
        forceLineMode: true,
      );
      final picked = await runner.select(
        'Tipe provider:',
        ['mock', 'ollama_native', 'gemini'],
      );
      expect(picked, 'gemini');
    });

    test('angka tidak valid diulang sampai valid', () async {
      final out = StringBuffer();
      final runner = PromptRunner(
        scriptedLines: ['99', 'x', ''],
        out: out,
        forceLineMode: true,
      );
      final picked = await runner.select(
        'Tipe provider:',
        ['mock', 'ollama_native'],
        def: 'mock',
      );
      expect(picked, 'mock');
      expect(out.toString(), contains('Pilih angka 1-2'));
    });

    test('setelah habis scripted, PromptAborted dilempar', () async {
      final runner = PromptRunner(
        scriptedLines: [],
        out: StringBuffer(),
        forceLineMode: true,
      );
      await expectLater(
        runner.select('Tipe provider:', ['mock']),
        throwsA(isA<PromptAborted>()),
      );
    });
  });

  group('PromptRunner.select (raw byte mode)', () {
    test('panah bawah lalu Enter memilih opsi kedua', () async {
      final out = StringBuffer();
      final runner = PromptRunner(
        inputStream: Stream.value(_bytes('\x1B[B\r')),
        out: out,
        history: const [],
      );
      final picked = await runner.select(
        'Tipe provider:',
        ['mock', 'ollama_native', 'gemini'],
      );
      expect(picked, 'ollama_native');
    });

    test('kursor default di opsi def; Enter langsung memilih', () async {
      final runner = PromptRunner(
        inputStream: Stream.value(_bytes('\r')),
        out: StringBuffer(),
        history: const [],
      );
      final picked = await runner.select(
        'Tipe provider:',
        ['mock', 'ollama_native'],
        def: 'ollama_native',
      );
      expect(picked, 'ollama_native');
    });

    test('angka 3 lompat langsung ke opsi ketiga', () async {
      final runner = PromptRunner(
        inputStream: Stream.value(_bytes('3\r')),
        out: StringBuffer(),
        history: const [],
      );
      final picked = await runner.select(
        'Tipe provider:',
        ['mock', 'ollama_native', 'gemini'],
      );
      expect(picked, 'gemini');
    });

    test('k key menaikkan kursor', () async {
      final runner = PromptRunner(
        inputStream: Stream.value(_bytes('k\r')),
        out: StringBuffer(),
        history: const [],
      );
      final picked = await runner.select(
        'Tipe provider:',
        ['mock', 'ollama_native'],
        def: 'ollama_native',
      );
      expect(picked, 'mock');
    });

    test('kursor membungkus: atas dari opsi pertama ke terakhir', () async {
      final runner = PromptRunner(
        inputStream: Stream.value(_bytes('\x1B[A\r')),
        out: StringBuffer(),
        history: const [],
      );
      final picked = await runner.select(
        'Tipe provider:',
        ['mock', 'ollama_native', 'gemini'],
      );
      expect(picked, 'gemini');
    });

    test('EOF tanpa Enter melempar PromptAborted', () async {
      final runner = PromptRunner(
        inputStream: Stream.value(_bytes('')),
        out: StringBuffer(),
        history: const [],
      );
      await expectLater(
        runner.select('Tipe provider:', ['mock']),
        throwsA(isA<PromptAborted>()),
      );
    });
  });
}

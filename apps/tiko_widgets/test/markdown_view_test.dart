import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tiko_widgets/src/gen_ui_view.dart';
import 'package:tiko_widgets/src/markdown_view.dart';

Widget host(String text) => MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(child: TikoMarkdownView(text: text)),
      ),
    );

void main() {
  group('parseMarkdownBlocks', () {
    test('heading, paragraf, dan kode terpisah', () {
      final blocks =
          parseMarkdownBlocks('# Judul\n\nparagraf\n\n```dart\nprint(1);\n```');
      expect(blocks, hasLength(3));
      expect((blocks[0] as MdHeading).level, 1);
      expect((blocks[0] as MdHeading).text, 'Judul');
      expect(blocks[1], isA<MdParagraph>());
      final code = blocks[2] as MdCode;
      expect(code.lang, 'dart');
      expect(code.code, 'print(1);');
    });

    test('code fence tanpa penutup tetap jadi blok (fail-open)', () {
      final blocks = parseMarkdownBlocks('```python\nx = 1\n');
      expect(blocks, hasLength(1));
      final code = blocks.single as MdCode;
      expect(code.lang, 'python');
      expect(code.code, 'x = 1');
    });

    test('bullet dan ordered list dengan lanjutan baris', () {
      final blocks = parseMarkdownBlocks('- satu\n  dua lanjutan\n\n1. pertama\n2. kedua');
      expect(blocks, hasLength(2));
      final bullet = blocks[0] as MdList;
      expect(bullet.ordered, isFalse);
      expect(bullet.items, ['satu dua lanjutan']);
      expect(bullet.checked, [null]);
      final ordered = blocks[1] as MdList;
      expect(ordered.ordered, isTrue);
      expect(ordered.items, ['pertama', 'kedua']);
    });

    test('task list GFM: [ ] dan [x] terdeteksi, marker dibuang dari teks', () {
      final blocks = parseMarkdownBlocks(
          '- [ ] beli kopi\n- [x] bayar listrik\n- biasa');
      final list = blocks.single as MdList;
      expect(list.items, ['beli kopi', 'bayar listrik', 'biasa']);
      expect(list.checked, [false, true, null]);
    });

    test('gambar standalone menjadi blok MdImage', () {
      final blocks = parseMarkdownBlocks(
          '![logo tiko](https://contoh.dev/logo.png)');
      final image = blocks.single as MdImage;
      expect(image.url, 'https://contoh.dev/logo.png');
      expect(image.alt, 'logo tiko');
    });

    test('tabel sederhana', () {
      final blocks = parseMarkdownBlocks(
          'nama | nilai\n--- | ---\nsatu | 1\ndua | 2');
      expect(blocks, hasLength(1));
      final table = blocks.single as MdTable;
      expect(table.header, ['nama', 'nilai']);
      expect(table.rows, [
        ['satu', '1'],
        ['dua', '2'],
      ]);
    });

    test('blockquote', () {
      final blocks = parseMarkdownBlocks('> baris satu\n> baris dua');
      expect(blocks, hasLength(1));
      expect((blocks.single as MdQuote).text, 'baris satu baris dua');
    });

    test('teks mentah tanpa throw', () {
      final blocks = parseMarkdownBlocks('[[[((( ))]]] \\\\ \\u0007');
      expect(blocks, isNotEmpty);
    });
  });

  group('buildInlineSpans', () {
    late TextStyle base, code, link;
    setUp(() {
      base = const TextStyle(fontSize: 14);
      code = base.copyWith(fontFamily: 'monospace');
      link = base.copyWith(color: Colors.blue);
    });

    test('bold, italic, inline code, link', () {
      final span = buildInlineSpans(
        '**tebal** biasa `kode` *itik* [label](https://x.dev)',
        base: base,
        codeStyle: code,
        linkStyle: link,
      );
      final texts = span.children!.map((c) => (c as TextSpan).text);
      expect(texts, contains('tebal'));
      expect(texts, contains('kode'));
      expect(texts, contains('itik'));
      expect(texts, contains('label'));
      final bold = span.children!.first as TextSpan;
      expect(bold.style!.fontWeight, FontWeight.w700);
    });

    test('markup tak berpasangan dirender apa adanya', () {
      final span = buildInlineSpans(
        'buka ** saja / pakai tanpa penutup',
        base: base,
        codeStyle: code,
        linkStyle: link,
      );
      final all = span.children!.map((c) => (c as TextSpan).text).join('');
      expect(all, 'buka ** saja / pakai tanpa penutup');
    });

    test('strikethrough ~~teks~~ dan link tidak tertukar', () {
      final span = buildInlineSpans(
        '~~hapus~~ dan [label](https://x.dev) ![alt](https://x.dev/i.png)',
        base: base,
        codeStyle: code,
        linkStyle: link,
      );
      final spans = span.children!;
      final strike = spans.map((c) => c is TextSpan ? c : null).nonNulls
          .singleWhere((s) => s.text == 'hapus');
      expect(strike.style!.decoration, TextDecoration.lineThrough);
      expect(spans.map((c) => c is TextSpan ? c.text : null), contains('label'));
      expect(spans.whereType<WidgetSpan>(), hasLength(1));
    });

    test('link biasa tidak ikut tertelan pola gambar', () {
      final span = buildInlineSpans(
        '[label](https://x.dev)',
        base: base,
        codeStyle: code,
        linkStyle: link,
      );
      expect(span.children!.whereType<WidgetSpan>(), isEmpty);
      expect(
        span.children!.map((c) => c is TextSpan ? c.text : null),
        contains('label'),
      );
    });
  });

  group('TikoMarkdownView (widget)', () {
    testWidgets('heading dan paragraf tampil', (tester) async {
      await tester.pumpWidget(host('# Judul\n\nisi paragraf'));
      expect(find.text('Judul'), findsOneWidget);
      expect(find.text('isi paragraf'), findsOneWidget);
    });

    testWidgets('code block punya tombol salin dan menyalin ke clipboard', (tester) async {
      final copied = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied.add((call.arguments as Map)['text'] as String? ?? '');
            return null;
          }
          return null;
        },
      );
      await tester.pumpWidget(host('```dart\nprint(1);\n```'));
      expect(find.byKey(const Key('md-code-copy')), findsOneWidget);
      await tester.tap(find.byKey(const Key('md-code-copy')));
      await tester.pump();
      expect(copied, ['print(1);']);
      expect(find.text('Kode tersalin'), findsOneWidget);
    });

    testWidgets('list dan table dirender', (tester) async {
      await tester.pumpWidget(host(
          '- satu\n- dua\n\ncol1 | col2\n--- | ---\na | b'));
      expect(find.textContaining('satu'), findsOneWidget);
      expect(find.text('col1'), findsOneWidget);
      expect(find.text('b'), findsOneWidget);
    });
  });

  testWidgets('GenUiMessageView merender markdown non-genui',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: GenUiMessageView(text: '## Ringkasan\n\njawaban akhir'),
        ),
      ),
    );
    expect(find.text('Ringkasan'), findsOneWidget);
    expect(find.text('jawaban akhir'), findsOneWidget);
  });

  testWidgets('GenUiMessageView dengan blok genui tetap berfungsi',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: GenUiMessageView(
            text: 'sebelum\n```genui\n{"type": "text", '
                '"text": "hasil genui", "style": "body"}\n```\n',
          ),
        ),
      ),
    );
    expect(find.text('hasil genui'), findsOneWidget);
    expect(find.text('sebelum'), findsOneWidget);
  });
}

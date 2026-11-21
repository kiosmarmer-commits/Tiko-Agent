/// C1 — renderer markdown minimal tanpa dependency pihak ketiga.
///
/// Mendukung subset yang paling sering muncul di balasan agent:
/// heading `#`–`######`, paragraf, bullet `- `/`* `, ordered `1. `,
/// blockquote `> `, tabel sederhana berpemisah `|`, inline `**bold**`,
/// `*italic*`, backtick `code`, link `[label](url)`, dan code fence
/// ``` ```lang … ``` ``` dengan tombol salin. BUKAN CommonMark penuh —
/// sintaks di luar subset dirender apa adanya (fail-open teks mentah).
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

sealed class MarkdownBlock {
  const MarkdownBlock();
}

class MdHeading extends MarkdownBlock {
  const MdHeading(this.level, this.text);
  final int level;
  final String text;
}

class MdParagraph extends MarkdownBlock {
  const MdParagraph(this.text);
  final String text;
}

class MdList extends MarkdownBlock {
  const MdList({required this.ordered, required this.items});
  final bool ordered;
  final List<String> items;
}

class MdQuote extends MarkdownBlock {
  const MdQuote(this.text);
  final String text;
}

class MdTable extends MarkdownBlock {
  const MdTable({required this.header, required this.rows});
  final List<String> header;
  final List<List<String>> rows;
}

class MdCode extends MarkdownBlock {
  const MdCode({this.lang, required this.code});
  final String? lang;
  final String code;
}

final RegExp _heading = RegExp(r'^(#{1,6})\s+(.*)$');
final RegExp _bullet = RegExp(r'^\s*[-*]\s+(.*)$');
final RegExp _ordered = RegExp(r'^\s*\d+[.)]\s+(.*)$');
final RegExp _tableSep = RegExp(r'^\s*\|?[\s:|-]*-[\s:|-]*\|?\s*$');
final RegExp _fence = RegExp(r'^(```|~~~)\s*([A-Za-z0-9_+#.-]*)\s*$');

/// Parse teks markdown menjadi blok-blok render. Tidak pernah throw —
/// baris yang tak dikenal masuk paragraf teks mentah.
List<MarkdownBlock> parseMarkdownBlocks(String source) {
  final blocks = <MarkdownBlock>[];
  final lines = const LineSplitter().convert(source);
  var i = 0;
  while (i < lines.length) {
    final line = lines[i];
    final fence = _fence.firstMatch(line);
    if (fence != null) {
      final lang = fence.group(2)?.trim();
      final marker = fence.group(1)!;
      final code = <String>[];
      i++;
      var closed = false;
      while (i < lines.length) {
        final candidate = lines[i];
        if (_fence.firstMatch(candidate) != null &&
            candidate.trimLeft().startsWith(marker)) {
          closed = true;
          i++;
          break;
        }
        code.add(candidate);
        i++;
      }
      blocks.add(MdCode(
        lang: lang != null && lang.isNotEmpty ? lang : null,
        code: code.join('\n'),
      ));
      if (!closed) break;
      continue;
    }
    if (line.trim().isEmpty) {
      i++;
      continue;
    }
    final heading = _heading.firstMatch(line);
    if (heading != null) {
      blocks.add(MdHeading(
        heading.group(1)!.length,
        heading.group(2)!.trim(),
      ));
      i++;
      continue;
    }
    final bulletMatch = _bullet.firstMatch(line);
    final orderedMatch = _ordered.firstMatch(line);
    if (bulletMatch != null || orderedMatch != null) {
      final ordered = bulletMatch == null;
      final items = <String>[
        (ordered ? orderedMatch! : bulletMatch).group(1)!.trim(),
      ];
      i++;
      while (i < lines.length && lines[i].trim().isNotEmpty) {
        final continuation = lines[i].trim();
        final nextBullet = _bullet.firstMatch(lines[i]);
        final nextOrdered = _ordered.firstMatch(lines[i]);
        if (nextBullet != null && !ordered) {
          items.add(nextBullet.group(1)!.trim());
          i++;
          continue;
        }
        if (nextOrdered != null && ordered) {
          items.add(nextOrdered.group(1)!.trim());
          i++;
          continue;
        }
        items[items.length - 1] = '${items.last} $continuation';
        i++;
      }
      blocks.add(MdList(ordered: ordered, items: items));
      continue;
    }
    if (line.trimLeft().startsWith('>')) {
      final quote = <String>[line.trimLeft().substring(1).trim()];
      i++;
      while (i < lines.length && lines[i].trim().isNotEmpty) {
        final q = lines[i];
        quote.add(q.trimLeft().startsWith('>')
            ? q.trimLeft().substring(1).trim()
            : q.trim());
        i++;
      }
      blocks.add(MdQuote(quote.join(' ')));
      continue;
    }
    if (line.contains('|') && i + 1 < lines.length && _tableSep.hasMatch(lines[i + 1])) {
      final header =
          splitTableRow(line).where((c) => c.isNotEmpty).toList();
      if (header.isNotEmpty) {
        i += 2;
        final rows = <List<String>>[];
        while (i < lines.length &&
            lines[i].trim().isNotEmpty &&
            lines[i].contains('|')) {
          rows.add(splitTableRow(lines[i]).where((c) => c.isNotEmpty).toList());
          i++;
        }
        blocks.add(MdTable(header: header, rows: rows));
        continue;
      }
    }
    final paragraph = <String>[line.trim()];
    i++;
    while (i < lines.length &&
        lines[i].trim().isNotEmpty &&
        _heading.firstMatch(lines[i]) == null &&
        _bullet.firstMatch(lines[i]) == null &&
        _ordered.firstMatch(lines[i]) == null &&
        _fence.firstMatch(lines[i]) == null &&
        !lines[i].trimLeft().startsWith('>')) {
      paragraph.add(lines[i].trim());
      i++;
    }
    blocks.add(MdParagraph(paragraph.join('\n')));
  }
  return blocks;
}

/// Pecah baris tabel; kosongkan sel pertama/terakhir kosong pada
/// bentuk `| a | b |` maupun `a | b`.
List<String> splitTableRow(String line) {
  var row = line.trim();
  if (row.startsWith('|')) row = row.substring(1);
  if (row.endsWith('|')) row = row.substring(0, row.length - 1);
  return [for (final c in row.split('|')) c.trim()];
}

final RegExp _inline = RegExp(
  r'(\*\*(.+?)\*\*)|(\*(.+?)\*)|(`(.+?)`)|(\[(.+?)\]\(([^)\s]+)\))',
  dotAll: true,
);

/// Ubah teks dengan markup inline menjadi [TextSpan] beranak:
/// `**bold**`, `*italic*`, `` `code` ``, `[label](url)`.
TextSpan buildInlineSpans(
  String text, {
  required TextStyle base,
  required TextStyle codeStyle,
  required TextStyle linkStyle,
}) {
  final spans = <InlineSpan>[];
  var last = 0;
  for (final m in _inline.allMatches(text)) {
    if (m.start > last) {
      spans.add(TextSpan(text: text.substring(last, m.start)));
    }
    if (m.group(1) != null) {
      spans.add(TextSpan(
        text: m.group(2),
        style: base.copyWith(fontWeight: FontWeight.w700),
      ));
    } else if (m.group(3) != null) {
      spans.add(TextSpan(
        text: m.group(4),
        style: base.copyWith(fontStyle: FontStyle.italic),
      ));
    } else if (m.group(5) != null) {
      spans.add(TextSpan(text: m.group(6), style: codeStyle));
    } else if (m.group(7) != null) {
      spans.add(TextSpan(
        text: m.group(8),
        style: linkStyle,
        recognizer: null,
      ));
    }
    last = m.end;
  }
  if (last < text.length) spans.add(TextSpan(text: text.substring(last)));
  return TextSpan(style: base, children: spans);
}

class TikoMarkdownView extends StatelessWidget {
  const TikoMarkdownView({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final base = theme.textTheme.bodyMedium ?? const TextStyle(fontSize: 14);
    final blocks = parseMarkdownBlocks(text);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < blocks.length; i++) ...[
          if (i > 0) const SizedBox(height: 8),
          _block(context, blocks[i], base),
        ],
      ],
    );
  }

  Widget _block(BuildContext context, MarkdownBlock block, TextStyle base) {
    final theme = Theme.of(context);
    final codeStyle = base.copyWith(
      fontFamily: 'monospace',
      fontSize: base.fontSize != null ? base.fontSize! - 1 : 13,
      color: theme.colorScheme.primary,
      backgroundColor: theme.colorScheme.surfaceContainerHighest,
    );
    final linkStyle = base.copyWith(color: theme.colorScheme.primary);
    switch (block) {
      case MdHeading(:final level, :final text):
        final size = switch (level) {
          1 => 22.0,
          2 => 19.0,
          3 => 17.0,
          _ => 16.0,
        };
        return SelectableText(
          text,
          style: base.copyWith(
            fontSize: size,
            fontWeight: FontWeight.w700,
            height: 1.25,
          ),
        );
      case MdParagraph(:final text):
        return SelectableText.rich(
          buildInlineSpans(
            text,
            base: base,
            codeStyle: codeStyle,
            linkStyle: linkStyle,
          ),
        );
      case MdQuote(:final text):
        return Container(
          padding: const EdgeInsets.only(left: 10),
          decoration: BoxDecoration(
            border: Border(
              left: BorderSide(color: theme.colorScheme.outline, width: 3),
            ),
          ),
          child: SelectableText(
            text,
            style: base.copyWith(fontStyle: FontStyle.italic, color: theme.colorScheme.onSurfaceVariant),
          ),
        );
      case MdList(:final ordered, :final items):
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < items.length; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 22,
                      child: Text(
                        ordered ? '${i + 1}.' : '\u2022',
                        style: base.copyWith(color: theme.colorScheme.onSurfaceVariant),
                      ),
                    ),
                    Expanded(
                      child: SelectableText.rich(
                        buildInlineSpans(
                          items[i],
                          base: base,
                          codeStyle: codeStyle,
                          linkStyle: linkStyle,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        );
      case MdTable(:final header, :final rows):
        return Container(
          decoration: BoxDecoration(
            border: Border.all(color: theme.colorScheme.outlineVariant),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              _tableRow(context, header, base.copyWith(fontWeight: FontWeight.w700)),
              for (final row in rows) _tableRow(context, row, base),
            ],
          ),
        );
      case MdCode(:final lang, :final code):
        return _MdCodeBlock(lang: lang, code: code, codeStyle: codeStyle);
    }
  }

  Widget _tableRow(BuildContext context, List<String> cells, TextStyle style) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final cell in cells.take(6))
            Expanded(child: SelectableText(cell, style: style)),
        ],
      ),
    );
  }
}

class _MdCodeBlock extends StatelessWidget {
  const _MdCodeBlock({
    required this.lang,
    required this.code,
    required this.codeStyle,
  });

  final String? lang;
  final String code;
  final TextStyle codeStyle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final surface = theme.brightness == Brightness.dark
        ? theme.colorScheme.surfaceContainerHighest
        : const Color(0xFF1E1E2E);
    final onSurface = theme.brightness == Brightness.dark
        ? theme.colorScheme.onSurface
        : const Color(0xFFEAEAF0);
    return Container(
      decoration: BoxDecoration(
        color: surface,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 6, 0),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    lang ?? 'kode',
                    style: TextStyle(fontSize: 11, color: onSurface.withValues(alpha: 0.6)),
                  ),
                ),
                IconButton(
                  key: const Key('md-code-copy'),
                  tooltip: 'Salin kode',
                  icon: Icon(Icons.copy_rounded, size: 14, color: onSurface.withValues(alpha: 0.7)),
                  onPressed: () => _copy(context),
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SelectableText(
                code,
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 13,
                  height: 1.5,
                  color: onSurface,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _copy(BuildContext context) {
    unawaited(Clipboard.setData(ClipboardData(text: code)));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Kode tersalin'), duration: Duration(seconds: 1)),
    );
  }
}

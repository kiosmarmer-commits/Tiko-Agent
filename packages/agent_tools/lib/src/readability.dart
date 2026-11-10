/// Readability-lite HTML to plain-text extraction, inspired by
/// trafilatura: prefer semantic main content, drop boilerplate,
/// keep heading markers and paragraph breaks.
///
/// Converts an HTML document to readable plain text.
String htmlToText(String html) {
  var s = html;
  // Prefer semantic main content when it carries most of the page.
  final main = RegExp(
    r'<(article|main)\b[^>]*>([\s\S]*?)</\1>',
    caseSensitive: false,
  ).firstMatch(s);
  if (main != null) {
    final inner = main.group(2) ?? '';
    if (inner.length * 2 > s.length) s = inner;
  }
  // Drop boilerplate blocks and comments.
  s = s
      .replaceAll(
        RegExp(
          r'<(script|style|nav|header|footer|aside|form|noscript)\b[^>]*>'
          r'[\s\S]*?</\1>',
          caseSensitive: false,
        ),
        ' ',
      )
      .replaceAll(RegExp(r'<!--[\s\S]*?-->'), ' ');
  // Headings become markdown-ish markers.
  s = s.replaceAllMapped(
    RegExp(r'<h([1-6])\b[^>]*>', caseSensitive: false),
    (m) {
      final level = int.tryParse(m.group(1) ?? '1') ?? 1;
      return '\n\n${'#' * level} ';
    },
  );
  // Close tags of block elements become line breaks.
  s = s
      .replaceAll(
        RegExp(
          r'</(p|div|li|tr|h[1-6]|section|article|blockquote)>',
          caseSensitive: false,
        ),
        '\n',
      )
      .replaceAll(RegExp(r'<br\b[^>]*>', caseSensitive: false), '\n');
  // Strip remaining tags and decode entities in a single pass.
  s = s
      .replaceAll(RegExp(r'<[^>]+>'), ' ')
      .replaceAllMapped(RegExp(r'&[a-zA-Z]+;'), _namedEntity)
      .replaceAllMapped(RegExp(r'&#(\d{1,7});'), (m) {
        final code = int.tryParse(m.group(1) ?? '32') ?? 32;
        return code > 0x10FFFF ? ' ' : String.fromCharCode(code);
      })
      .replaceAllMapped(RegExp(r'&#x([0-9a-fA-F]{1,6});'), (m) {
        final code = int.tryParse(m.group(1) ?? '20', radix: 16) ?? 0x20;
        return code > 0x10FFFF ? ' ' : String.fromCharCode(code);
      });
  // Collapse per-line whitespace, drop blank and repeated lines.
  final lines = s
      .split('\n')
      .map((l) => l.replaceAll(RegExp(r'\s+'), ' ').trim())
      .where((l) => l.isNotEmpty)
      .toList();
  final out = <String>[];
  for (final line in lines) {
    if (out.isEmpty || out.last != line) out.add(line);
  }
  return out.join('\n');
}

const _namedEntities = <String, String>{
  '&nbsp;': ' ',
  '&amp;': '&',
  '&lt;': '<',
  '&gt;': '>',
  '&quot;': '"',
  "&apos;": "'",
  '&ndash;': '-',
  '&mdash;': '--',
};

String _namedEntity(Match m) {
  final name = m.group(0) ?? '';
  return _namedEntities[name] ?? name;
}

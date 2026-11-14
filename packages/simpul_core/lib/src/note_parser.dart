import 'package:meta/meta.dart';

/// A parsed internal link (FR-02, FR-20..22).
///
/// Syntax compatibility with Obsidian (help.obsidian.md/help/links):
/// - `[[Note]]`, `[[Note.md]]`, `[[folder/Note]]`
/// - `[[Note|Display]]` (alias / display text)
/// - `[[Note#Heading]]`, `[[Note#^block-id]]`, `[[#Heading]]` (same note)
/// - `![[Note]]`, `![[image.png|300]]`, `![[Doc.pdf#page=3]]` (embeds)
/// - Markdown links `[text](Note.md)` and `[text](folder/Note)` (percent-encoded)
@immutable
class ParsedLink {
  const ParsedLink({
    required this.target,
    required this.anchor,
    required this.alias,
    required this.kind,
    required this.embed,
    required this.offset,
  });

  /// Link destination without `.md` suffix and without anchor. Empty means
  /// same-note reference (`[[#Heading]]`).
  final String target;

  /// Heading text or `^block-id` after `#`; empty when absent.
  final String anchor;

  /// Display text (alias); empty when the link has none.
  final String alias;

  /// `wikilink` or `mdlink`.
  final String kind;

  /// True for embeds (`![[...]]`).
  final bool embed;

  /// Character offset of the link in the note body.
  final int offset;
}

/// A chunk of the note body under one heading chain (AI-10).
@immutable
class NoteChunk {
  const NoteChunk({
    required this.headingPath,
    required this.startChar,
    required this.endChar,
    required this.text,
  });

  /// e.g. `Setup > Editor > Live preview`; empty for the intro chunk.
  final String headingPath;
  final int startChar;
  final int endChar;
  final String text;
}

/// Fully parsed note ready for indexing (PRD DATA-10).
@immutable
class ParsedNote {
  const ParsedNote({
    required this.path,
    required this.title,
    required this.props,
    required this.tags,
    required this.aliases,
    required this.links,
    required this.blockIds,
    required this.chunks,
    required this.wordCount,
    required this.body,
    this.aiAccess = 'ask',
  });

  /// Vault-relative POSIX path, e.g. `catatan/ide.md`.
  final String path;
  final String title;
  final Map<String, Object?> props;
  final List<String> tags;
  final List<String> aliases;
  final List<ParsedLink> links;
  final List<String> blockIds;
  final List<NoteChunk> chunks;
  final int wordCount;

  /// Body text without frontmatter (source for FTS and snippets).
  final String body;

  /// Per-note AI access rule from the `ai-access` frontmatter property
  /// (AI-42): `allow`, `ask` (default when absent), or `deny`.
  final String aiAccess;
}

/// Parser for Obsidian-compatible Markdown notes.
abstract final class NoteParser {
  /// Parses [raw] content of the file at vault-relative [path].
  static ParsedNote parse(String path, String raw) {
    final frontmatter = _extractFrontmatter(raw);
    final props = frontmatter.props;
    final body = frontmatter.body;

    final masked = _maskCode(body);
    final links = _parseLinks(masked);
    final inlineTags = _parseInlineTags(masked);
    final frontTags = _stringList(props['tags']);
    final aliases = _stringList(props['aliases']);
    final blockIds = _parseBlockIds(body);

    final tagSet = <String>{};
    for (final t in frontTags) {
      final clean = _cleanTag(t);
      if (clean.isNotEmpty) tagSet.add(clean);
    }
    tagSet.addAll(inlineTags);

    final chunks = _chunkByHeading(body);
    final wordCount = _countWords(body);
    final basename = _basename(path);
    final title = (props['title'] as String?)?.trim().isNotEmpty == true
        ? (props['title'] as String).trim()
        : basename;

    return ParsedNote(
      path: path,
      title: title,
      props: props,
      tags: tagSet.toList(growable: false),
      aliases: aliases,
      links: links,
      blockIds: blockIds,
      chunks: chunks,
      wordCount: wordCount,
      body: body,
      aiAccess: noteAiAccess(props),
    );
  }

  /// Per-note AI access rule (AI-42) from the `ai-access` frontmatter
  /// property. Absent or malformed values fall back to `ask` (fail-safe).
  static String noteAiAccess(Map<String, Object?> props) {
    final raw = props['ai-access'] ?? props['ai_access'];
    if (raw == null) return 'ask';
    return switch (raw.toString().trim().toLowerCase()) {
      'izin' || 'izin penuh' || 'allow' => 'allow',
      'tolak' || 'deny' => 'deny',
      _ => 'ask',
    };
  }

  static String _basename(String path) {
    final withoutDir = path.contains('/') ? path.substring(path.lastIndexOf('/') + 1) : path;
    return withoutDir.endsWith('.md') ? withoutDir.substring(0, withoutDir.length - 3) : withoutDir;
  }

  static ({Map<String, Object?> props, String body}) _extractFrontmatter(String raw) {
    final match = RegExp(r'^---\r?\n(.*?)\r?\n---\r?\n?', dotAll: true).firstMatch(raw);
    if (match == null) return (props: <String, Object?>{}, body: raw);
    return (props: _parseYamlSubset(match.group(1)!), body: raw.substring(match.end));
  }

  /// Minimal YAML subset sufficient for Obsidian properties (FR-23):
  /// scalars, quoted strings, booleans, numbers, and `- item` lists.
  static Map<String, Object?> _parseYamlSubset(String yaml) {
    final props = <String, Object?>{};
    String? currentKey;
    final currentList = <String>[];
    void flushList() {
      final key = currentKey;
      if (key != null) {
        props[key] = List<String>.from(currentList);
      }
      currentKey = null;
      currentList.clear();
    }

    for (final rawLine in yaml.split('\n')) {
      final line = rawLine.replaceFirst(RegExp(r'\r$'), '');
      if (line.trim().isEmpty) continue;
      final listItem = RegExp(r'^\s+-\s?(.*)$').firstMatch(line);
      if (listItem != null && currentKey != null) {
        final item = _scalar(listItem.group(1)!.trim());
        currentList.add(item is List ? item.join(', ') : item.toString());
        continue;
      }
      final kv = RegExp(r'^([A-Za-z0-9_\- ]+):\s*(.*)$').firstMatch(line);
      if (kv == null) continue;
      flushList();
      final key = kv.group(1)!.trim();
      final value = kv.group(2)!.trim();
      if (value.isEmpty) {
        currentKey = key;
      } else {
        props[key] = _scalar(value);
      }
    }
    flushList();
    return props;
  }

  static Object? _scalar(String raw) {
    final value = raw;
    if (value.length >= 2 &&
        ((value.startsWith('"') && value.endsWith('"')) ||
            (value.startsWith("'") && value.endsWith("'")))) {
      return value.substring(1, value.length - 1);
    }
    if (value.startsWith('[') && value.endsWith(']')) {
      final inner = value.substring(1, value.length - 1).trim();
      if (inner.isEmpty) return <String>[];
      return inner.split(',').map((e) => _scalar(e.trim())).toList(growable: false);
    }
    if (value == 'true') return true;
    if (value == 'false') return false;
    final asInt = int.tryParse(value);
    if (asInt != null) return asInt;
    final asDouble = double.tryParse(value);
    if (asDouble != null) return asDouble;
    return value;
  }

  static List<String> _stringList(Object? value) {
    if (value is List) {
      return value.map((e) => e.toString().trim()).where((s) => s.isNotEmpty).toList();
    }
    if (value is String && value.trim().isNotEmpty) {
      return value
          .split(',')
          .map((e) => e.trim())
          .where((s) => s.isNotEmpty)
          .toList();
    }
    return const [];
  }

  /// Replaces fenced code blocks, inline code, and `%%comments%%` with spaces
  /// of identical length so offsets stay valid but syntax inside is ignored.
  static String _maskCode(String body) {
    final out = StringBuffer();
    var inFence = false;
    for (final line in LineSplitterCompat.split(body)) {
      if (line.trimLeft().startsWith('```')) {
        inFence = !inFence;
        out.writeln(' ' * line.length);
        continue;
      }
      out.writeln(inFence ? ' ' * line.length : _maskInline(line));
    }
    return out.toString();
  }

  static String _maskInline(String line) {
    var out = line;
    out = out.replaceAllMapped(RegExp(r'`[^`]*`'), (m) => ' ' * m.group(0)!.length);
    out = out.replaceAllMapped(RegExp(r'%%.*?%%'), (m) => ' ' * m.group(0)!.length);
    return out;
  }

  static List<ParsedLink> _parseLinks(String masked) {
    final links = <ParsedLink>[];
    final wiki = RegExp(r'!?\[\[([^\[\]]+?)\]\]');
    for (final m in wiki.allMatches(masked)) {
      final inner = m.group(1)!;
      final embed = m.group(0)!.startsWith('!');
      final parts = inner.split('|');
      final targetPart = parts[0].trim();
      final alias = parts.length > 1 ? parts.sublist(1).join('|').trim() : '';
      final hash = targetPart.indexOf('#');
      var target = hash >= 0 ? targetPart.substring(0, hash).trim() : targetPart;
      final anchor = hash >= 0 ? targetPart.substring(hash + 1).trim() : '';
      if (target.endsWith('.md')) target = target.substring(0, target.length - 3);
      links.add(ParsedLink(
        target: target,
        anchor: anchor,
        alias: alias,
        kind: 'wikilink',
        embed: embed,
        offset: m.start,
      ));
    }

    final md = RegExp(r'(?<!\!)\[([^\]]*)\]\(([^)\s]+)(?:\s+"[^"]*")?\)');
    for (final m in md.allMatches(masked)) {
      final rawTarget = Uri.decodeComponent(m.group(2)!);
      if (RegExp(r'^(https?|mailto|file):').hasMatch(rawTarget)) continue;
      if (rawTarget.startsWith('#')) continue;
      var target = rawTarget.split('#').first.trim();
      final anchor = rawTarget.contains('#') ? rawTarget.split('#')[1].trim() : '';
      if (target.endsWith('.md')) target = target.substring(0, target.length - 3);
      if (target.isEmpty) continue;
      links.add(ParsedLink(
        target: target,
        anchor: anchor,
        alias: m.group(1)!.trim(),
        kind: 'mdlink',
        embed: false,
        offset: m.start,
      ));
    }
    return links;
  }

  /// Inline tags per Obsidian rules: `#a/b`, letters/digits/_-//emoji,
  /// at least one non-digit character, no spaces, not a heading.
  static List<String> _parseInlineTags(String masked) {
    final tags = <String>{};
    final pattern = RegExp(r'(?:^|[\s(])#([^\s#\[\]:]+)', multiLine: true);
    for (final m in pattern.allMatches(masked)) {
      final tag = _cleanTag(m.group(1)!);
      if (tag.isNotEmpty) tags.add(tag);
    }
    return tags.toList(growable: false);
  }

  static String _cleanTag(String raw) {
    var tag = raw.trim();
    while (tag.isNotEmpty && '.,;:!?)'.contains(tag[tag.length - 1])) {
      tag = tag.substring(0, tag.length - 1);
    }
    if (tag.isEmpty) return '';
    if (RegExp(r'^\d+$').hasMatch(tag)) return '';
    if (!RegExp(r'^[\w\-\/]+$').hasMatch(tag)) return '';
    return tag;
  }

  static List<String> _parseBlockIds(String body) {
    final ids = <String>[];
    final pattern = RegExp(r'\^([A-Za-z0-9\-]+)\s*$', multiLine: true);
    for (final m in pattern.allMatches(body)) {
      ids.add(m.group(1)!);
    }
    return ids;
  }

  /// Chunks the body per heading with `heading_path` chains (AI-10).
  static List<NoteChunk> _chunkByHeading(String body) {
    final chunks = <NoteChunk>[];
    final stack = <({int level, String text})>[];
    final linePattern = RegExp(r'^(#{1,6})\s+(.+?)\s*#*\s*$', multiLine: true);
    final matches = linePattern.allMatches(body).toList();

    var cursor = 0;
    var path = <String>[];
    void emit(int end) {
      if (end <= cursor) return;
      final text = body.substring(cursor, end);
      if (text.trim().isEmpty) return;
      chunks.add(NoteChunk(
        headingPath: path.join(' > '),
        startChar: cursor,
        endChar: end,
        text: text,
      ));
    }

    for (final m in matches) {
      emit(m.start);
      final level = m.group(1)!.length;
      final text = m.group(2)!.trim();
      while (stack.isNotEmpty && stack.last.level >= level) {
        stack.removeLast();
      }
      stack.add((level: level, text: text));
      path = stack.map((s) => s.text).toList();
      cursor = m.end;
    }
    emit(body.length);
    if (chunks.isEmpty && body.trim().isNotEmpty) {
      chunks.add(NoteChunk(
        headingPath: '',
        startChar: 0,
        endChar: body.length,
        text: body,
      ));
    }
    return chunks;
  }

  static int _countWords(String body) {
    final matches = RegExp(r'\S+').allMatches(body);
    return matches.length;
  }
}

/// Line splitting without importing dart:convert at every call site.
abstract final class LineSplitterCompat {
  static List<String> split(String input) => input.split('\n');
}

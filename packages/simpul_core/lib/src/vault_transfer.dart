/// Vault import/export (FR-70, FR-71, FR-72).
///
/// - [VaultImporter.importFolder] migrates an existing vault folder from
///   Obsidian, Logseq, Joplin, or Notion into a Simpul vault (copy `.md`
///   notes + rewrite links where the source format differs).
/// - [VaultExporter.noteToHtml] renders a minimal Markdown subset to HTML
///   for sharing notes outside the app (FR-71).
/// - [VaultExporter.graphToJson] / [VaultExporter.graphToGraphml] export the
///   link graph for external tools (Obsidian graph JSON, Gephi/GraphML).
library;

import 'dart:convert';
import 'dart:io';

import 'graph_csr.dart';

/// Source vault formats understood by [VaultImporter].
enum ImportFormat { obsidian, logseq, joplin, notion }

/// Result of one import run.
class ImportResult {
  ImportResult({
    required this.notesCopied,
    required this.attachmentsCopied,
    required this.linksRewritten,
    required this.skipped,
  });

  int notesCopied;
  int attachmentsCopied;
  int linksRewritten;
  final List<String> skipped;
}

/// Imports an existing vault folder into a Simpul vault.
class VaultImporter {
  /// Copies Markdown notes (and attachments) from [sourceDir] into
  /// [destDir], applying [format]-specific normalization.
  ///
  /// Common behavior: hidden folders (`.obsidian`, `.git`, `.trash`,
  /// `.simpul`) and non-Markdown junk are skipped; paths are preserved
  /// relative to the vault root so Obsidian folders round-trip losslessly.
  static Future<ImportResult> importFolder(
    Directory sourceDir,
    Directory destDir, {
    ImportFormat format = ImportFormat.obsidian,
  }) async {
    if (!await sourceDir.exists()) {
      throw StateError('Source vault not found: ${sourceDir.path}');
    }
    final result = ImportResult(
      notesCopied: 0,
      attachmentsCopied: 0,
      linksRewritten: 0,
      skipped: [],
    );
    final skipDirs = <String>{
      '.git',
      '.obsidian',
      '.trash',
      '.simpul',
      '.joplin',
      if (format == ImportFormat.logseq) 'logseq',
    };
    final srcRoot = sourceDir.path;
    final files = <File>[];
    await for (final entity
        in sourceDir.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      final rel = entity.path.substring(srcRoot.length);
      final segments = rel
          .split(Platform.pathSeparator)
          .where((s) => s.isNotEmpty)
          .toList();
      if (segments.isEmpty) continue;
      if (segments.any(skipDirs.contains)) continue;
      if (segments.any((s) => s.startsWith('~') || s.endsWith('.tmp'))) {
        continue;
      }
      final isNote = segments.last.toLowerCase().endsWith('.md');
      if (!isNote && format == ImportFormat.logseq) continue;
      files.add(entity);
    }

    await destDir.create(recursive: true);
    final usedNames = <String>{};
    for (final file in files) {
      final rel = file.path.substring(srcRoot.length);
      final segments = rel
          .split(Platform.pathSeparator)
          .where((s) => s.isNotEmpty)
          .toList();
      final isNote = segments.last.toLowerCase().endsWith('.md');
      try {
        if (isNote) {
          final name = _normalizeNoteName(segments.last, format);
          final folder = segments.length > 1
              ? segments.sublist(0, segments.length - 1).join('/')
              : '';
          var targetRel = folder.isEmpty ? name : '$folder/$name';
          if (format == ImportFormat.logseq) {
            targetRel = 'pages/$name';
          }
          targetRel = _dedupe(targetRel, usedNames);
          final dest = File(
              '${destDir.path}${Platform.pathSeparator}'
              '${targetRel.replaceAll('/', Platform.pathSeparator)}');
          await dest.parent.create(recursive: true);
          var body = await file.readAsString();
          if (format == ImportFormat.logseq) {
            final converted = _logseqToMarkdown(body);
            result.linksRewritten += converted.$2;
            body = converted.$1;
          }
          body = _rewriteNotionLinks(body, format);
          await dest.writeAsString(body);
          result.notesCopied++;
        } else {
          final dest = File(
              '${destDir.path}${Platform.pathSeparator}'
              '${segments.join(Platform.pathSeparator)}');
          await dest.parent.create(recursive: true);
          await file.copy(dest.path);
          result.attachmentsCopied++;
        }
      } on FileSystemException catch (e) {
        result.skipped.add('${segments.join('/')}: ${e.message}');
      }
    }
    return result;
  }

  static String _normalizeNoteName(String fileName, ImportFormat format) {
    var name = fileName;
    if (format == ImportFormat.notion) {
      // Notion exports `Page 1a2b3c...e9.md` (32-hex uuid suffix).
      name = name.replaceAll(
          RegExp(r'\s+([0-9a-fA-F]{32})\.md$', caseSensitive: false), '.md');
      name = name.replaceAll(
          RegExp(r'\s+([0-9a-fA-F]{32})$', caseSensitive: false), '');
    }
    return name;
  }

  /// Notion embeds a 32-hex uuid after page names in file names, link
  /// labels, and URLs (`Page <uuid>`, `Page%20<uuid>`); strip those
  /// occurrences so `[[Page]]`-style resolution keeps working.
  static String _rewriteNotionLinks(String body, ImportFormat format) {
    if (format != ImportFormat.notion) return body;
    return body.replaceAll(
        RegExp(r'(%20|\s)[0-9a-fA-F]{32}', caseSensitive: false), '');
  }

  /// Logseq stores page links as `[[page]]` (fine) and block refs as
  /// `((block-id))`; convert block refs into plain text markers.
  /// Returns the converted body plus the number of rewritten constructs.
  static (String, int) _logseqToMarkdown(String body) {
    var count = 0;
    final out = body.replaceAllMapped(
        RegExp(r'\(\(([A-Za-z0-9_-]{6,})\)\)'), (m) {
      count++;
      return '`block:${m.group(1)}`';
    });
    return (out, count);
  }

  static String _dedupe(String rel, Set<String> used) {
    if (used.add(rel)) return rel;
    final dot = rel.lastIndexOf('.');
    final base = dot < 0 ? rel : rel.substring(0, dot);
    final ext = dot < 0 ? '' : rel.substring(dot);
    var i = 2;
    while (!used.add('$base $i$ext')) {
      i++;
    }
    return '$base $i$ext';
  }
}

/// Exports notes and graphs to interchange formats.
class VaultExporter {
  /// Renders a Markdown subset to standalone HTML (FR-71).
  ///
  /// Handles: ATX headings 1-6, fenced code blocks, blockquotes, unordered
  /// and ordered lists, checkboxes, bold/italic/inline code, wikilinks,
  /// markdown links, and paragraphs. Wikilinks become `<span
  /// class="wikilink">` so the output stays valid without a resolver.
  static String noteToHtml(String markdown, {String title = ''}) {
    final lines = const LineSplitter().convert(markdown);
    final html = <String>[];
    var inCode = false;
    var listOpen = false;

    String inline(String text) {
      var t = _escapeHtml(text);
      t = t.replaceAllMapped(
          RegExp(r'\[\[([^\]|]+)(?:\|([^\]]+))?\]\]'), (m) {
        final target = m.group(1)!.trim();
        final label = (m.group(2) ?? target).trim();
        return '<span class="wikilink" data-target="'
            '${_escapeAttr(target)}">$label</span>';
      });
      t = t.replaceAllMapped(RegExp(r'\[([^\]]+)\]\(([^)]+)\)'),
          (m) => '<a href="${_escapeAttr(m.group(2)!)}">'
              '${m.group(1)}</a>');
      t = t.replaceAllMapped(RegExp(r'\*\*([^*]+)\*\*'),
          (m) => '<strong>${m.group(1)}</strong>');
      t = t.replaceAllMapped(RegExp(r'(?<!\*)\*([^*]+)\*(?!\*)'),
          (m) => '<em>${m.group(1)}</em>');
      t = t.replaceAllMapped(RegExp(r'`([^`]+)`'),
          (m) => '<code>${m.group(1)}</code>');
      return t;
    }

    void closeList() {
      if (listOpen) {
        html.add('</ul>');
        listOpen = false;
      }
    }

    for (final raw in lines) {
      if (raw.trimLeft().startsWith('```')) {
        closeList();
        html.add(inCode ? '</code></pre>' : '<pre><code>');
        inCode = !inCode;
        continue;
      }
      if (inCode) {
        html.add(_escapeHtml(raw));
        continue;
      }
      final heading = RegExp(r'^(#{1,6})\s+(.*)$').firstMatch(raw);
      if (heading != null) {
        closeList();
        final level = heading.group(1)!.length;
        html.add('<h$level>${inline(heading.group(2)!)}</h$level>');
        continue;
      }
      final quote = RegExp(r'^>\s?(.*)$').firstMatch(raw);
      if (quote != null) {
        closeList();
        html.add('<blockquote>${inline(quote.group(1)!)}</blockquote>');
        continue;
      }
      final check =
          RegExp(r'^\s*[-*]\s+\[( |x|X)\]\s+(.*)$').firstMatch(raw);
      if (check != null) {
        if (!listOpen) {
          html.add('<ul>');
          listOpen = true;
        }
        final done = check.group(1)!.toLowerCase() == 'x';
        html.add('<li><input type="checkbox" disabled'
            '${done ? ' checked' : ''}> ${inline(check.group(2)!)}</li>');
        continue;
      }
      final bullet = RegExp(r'^\s*[-*]\s+(.*)$').firstMatch(raw);
      if (bullet != null) {
        if (!listOpen) {
          html.add('<ul>');
          listOpen = true;
        }
        html.add('<li>${inline(bullet.group(1)!)}</li>');
        continue;
      }
      final ordered = RegExp(r'^\s*\d+[.)]\s+(.*)$').firstMatch(raw);
      if (ordered != null) {
        if (!listOpen) {
          html.add('<ul>');
          listOpen = true;
        }
        html.add('<li>${inline(ordered.group(1)!)}</li>');
        continue;
      }
      closeList();
      if (raw.trim().isEmpty) continue;
      html.add('<p>${inline(raw.trim())}</p>');
    }
    closeList();
    if (inCode) html.add('</code></pre>');

    final out = StringBuffer();
    out.writeln('<!DOCTYPE html>');
    out.writeln('<html lang="en"><head><meta charset="utf-8">');
    out.writeln(
        '<title>${_escapeHtml(title.isEmpty ? 'Note' : title)}</title>');
    out.writeln('<style>body{font-family:sans-serif;max-width:44em;'
        'margin:2em auto;padding:0 1em;line-height:1.55}'
        'blockquote{border-left:4px solid #ccc;margin:0;padding-left:1em;'
        'color:#555}code{background:#f4f4f4;padding:0 .3em;border-radius:3px}'
        'pre code{display:block;padding:1em}</style>');
    out.writeln('</head><body>');
    for (final line in html) {
      out.writeln(line);
    }
    out.writeln('</body></html>');
    return out.toString();
  }

  /// Exports the link graph to Obsidian-compatible JSON (FR-72):
  /// `{"nodes":[{"id":path,"x":..,"y":..}],"edges":[{"source":..,"target":..}]}`.
  static Map<String, dynamic> graphToJson(GraphCsr graph) {
    final nodes = <Map<String, dynamic>>[];
    for (var i = 0; i < graph.nodeCount; i++) {
      nodes.add({
        'id': graph.paths[i],
        'x': graph.positionsX[i],
        'y': graph.positionsY[i],
      });
    }
    final edges = <Map<String, dynamic>>[];
    for (var i = 0; i < graph.nodeCount; i++) {
      for (var k = graph.offsets[i]; k < graph.offsets[i + 1]; k++) {
        edges.add({
          'source': graph.paths[i],
          'target': graph.paths[graph.targets[k]],
        });
      }
    }
    return {'nodes': nodes, 'edges': edges};
  }

  /// Exports the link graph as GraphML XML (FR-72) for Gephi/yEd.
  static String graphToGraphml(GraphCsr graph) {
    final out = StringBuffer();
    out.writeln('<?xml version="1.0" encoding="UTF-8"?>');
    out.writeln('<graphml xmlns="http://graphml.graphdrawing.org/xmlns">');
    out.writeln(
        '  <key id="d0" for="node" attr.name="x" attr.type="double"/>');
    out.writeln(
        '  <key id="d1" for="node" attr.name="y" attr.type="double"/>');
    out.writeln('  <graph id="G" edgedefault="directed">');
    for (var i = 0; i < graph.nodeCount; i++) {
      out.writeln('    <node id="${_escapeAttr(graph.paths[i])}">');
      out.writeln('      <data key="d0">${graph.positionsX[i]}</data>');
      out.writeln('      <data key="d1">${graph.positionsY[i]}</data>');
      out.writeln('    </node>');
    }
    for (var i = 0; i < graph.nodeCount; i++) {
      for (var k = graph.offsets[i]; k < graph.offsets[i + 1]; k++) {
        out.writeln('    <edge source="${_escapeAttr(graph.paths[i])}"'
            ' target="${_escapeAttr(graph.paths[graph.targets[k]])}"/>');
      }
    }
    out.writeln('  </graph>');
    out.writeln('</graphml>');
    return out.toString();
  }

  static String _escapeHtml(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');

  static String _escapeAttr(String s) => _escapeHtml(s)
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&#39;');
}

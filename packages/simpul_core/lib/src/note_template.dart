/// Note templates (FR-43) \u2014 reusable note skeletons with variable
/// interpolation, stored per-vault under `.simpul/templates/*.md`.
///
/// Supported variables ( Obsidian core-templates compatible subset):
/// `{{title}}`, `{{date}}` (yyyy-MM-dd), `{{time}}` (HH:mm), `{{path}}`
/// (vault-relative target path without extension). Unknown variables are
/// left untouched so third-party plugins keep working after import.
library;

import 'dart:io';

/// Renders template bodies by substituting `{{var}}` placeholders.
class NoteTemplate {
  /// Returns [body] with every known variable replaced.
  ///
  /// [extraVars] wins over the built-ins, enabling custom frontmatter-driven
  /// variables later without changing this call site.
  static String render(
    String body, {
    String title = '',
    String path = '',
    DateTime? now,
    Map<String, String> extraVars = const {},
  }) {
    final stamp = now ?? DateTime.now();
    String pad2(int v) => v.toString().padLeft(2, '0');
    final vars = <String, String>{
      'title': title,
      'path': path,
      'date': '${stamp.year}-${pad2(stamp.month)}-${pad2(stamp.day)}',
      'time': '${pad2(stamp.hour)}:${pad2(stamp.minute)}',
      ...extraVars,
    };
    return body.replaceAllMapped(RegExp(r'\{\{\s*([A-Za-z0-9_.-]+)\s*\}\}'),
        (m) {
      final key = m.group(1)!.toLowerCase();
      return vars[key] ?? m.group(0)!;
    });
  }

  /// Suggests a file name for a new note from a template title.
  static String sanitizeFileName(String title) {
    final cleaned = title
        .replaceAll(RegExp(r'[\\/:*?"<>|#^\[\]]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return cleaned.isEmpty ? 'Untitled' : cleaned;
  }
}

/// Discovers and creates templates under `<vaultDir>/.simpul/templates/`.
class TemplateStore {
  static const String templatesDirName = '.simpul/templates';

  /// Lists available templates sorted by name. Missing directory is not an
  /// error: a fresh vault simply has no templates yet.
  static Future<List<TemplateFile>> listTemplates(Directory vaultDir) async {
    final dir = Directory(
        '${vaultDir.path}${Platform.pathSeparator}$templatesDirName');
    if (!await dir.exists()) return const [];
    final files = <TemplateFile>[];
    await for (final entity in dir.list()) {
      if (entity is! File) continue;
      if (!entity.path.endsWith('.md')) continue;
      final name = entity.uri.pathSegments.last;
      files.add(TemplateFile(
        name: name.substring(0, name.length - 3),
        file: entity,
      ));
    }
    files.sort((a, b) => a.name.compareTo(b.name));
    return files;
  }

  /// Reads a template body by template name (without `.md`).
  static Future<String?> read(Directory vaultDir, String name) async {
    final file = File(
        '${vaultDir.path}${Platform.pathSeparator}$templatesDirName'
        '${Platform.pathSeparator}$name.md');
    if (!await file.exists()) return null;
    return file.readAsString();
  }

  /// Creates (or overwrites) a template. Parent directories are created
  /// on demand so a vault can bootstrap its first template via CLI.
  static Future<File> create(
      Directory vaultDir, String name, String body) async {
    final dir = Directory(
        '${vaultDir.path}${Platform.pathSeparator}$templatesDirName');
    await dir.create(recursive: true);
    final safe = NoteTemplate.sanitizeFileName(name);
    return File(
            '${dir.path}${Platform.pathSeparator}$safe.md')
        .writeAsString(body);
  }
}

/// A discovered template file.
class TemplateFile {
  TemplateFile({required this.name, required this.file});

  /// Template name without the `.md` extension.
  final String name;
  final File file;
}

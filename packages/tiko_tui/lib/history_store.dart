import 'dart:convert';
import 'dart:io';

/// Persists TUI/prompt history across sessions (most recent last).
class TuiHistoryStore {
  TuiHistoryStore(this.path);

  final String path;

  List<String> load({int limit = 500}) {
    final file = File(path);
    if (!file.existsSync()) return [];
    try {
      final lines = const LineSplitter()
          .convert(file.readAsStringSync())
          .where((l) => l.trim().isNotEmpty)
          .toList();
      return lines.length <= limit ? lines : lines.sublist(lines.length - limit);
    } on FileSystemException {
      return [];
    }
  }

  Future<void> save(List<String> lines, {int limit = 500}) async {
    final trimmed = lines.length <= limit
        ? lines
        : lines.sublist(lines.length - limit);
    await File(path).parent.create(recursive: true);
    await File(path).writeAsString(
      '${trimmed.join('\n')}\n',
      flush: true,
    );
  }
}

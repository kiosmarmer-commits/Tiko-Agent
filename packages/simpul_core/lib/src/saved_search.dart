/// Saved searches (FR-34): named queries persisted per vault under
/// `.simpul/searches.json`. Plain JSON (no crypto) — a search string leaks
/// nothing beyond what the vault already shows.
library;

import 'dart:convert';
import 'dart:io';

class SavedSearch {
  const SavedSearch({
    required this.name,
    required this.query,
    required this.createdAt,
  });

  final String name;
  final String query;
  final String createdAt;

  Map<String, Object?> toJson() => {
        'name': name,
        'query': query,
        'created_at': createdAt,
      };

  static SavedSearch fromJson(Map<String, Object?> json) => SavedSearch(
        name: json['name']!.toString(),
        query: json['query']!.toString(),
        createdAt: json['created_at']?.toString() ?? '',
      );
}

/// CRUD over `<vaultDir>/.simpul/searches.json`. A corrupt file fails closed
/// (throws) rather than being silently reset — the user can delete it
/// manually to start over.
class SavedSearchStore {
  SavedSearchStore(this.vaultDir);

  final String vaultDir;

  String get _path =>
      '$vaultDir${Platform.pathSeparator}.simpul'
      '${Platform.pathSeparator}searches.json';

  Future<List<SavedSearch>> list() async {
    final file = File(_path);
    if (!await file.exists()) return const [];
    final decoded =
        (jsonDecode(await file.readAsString()) as List).cast<Map>();
    return [
      for (final entry in decoded)
        SavedSearch.fromJson(entry.cast<String, Object?>()),
    ];
  }

  Future<void> save(String name, String query) async {
    if (name.trim().isEmpty || query.trim().isEmpty) {
      throw ArgumentError('nama dan kueri tidak boleh kosong');
    }
    final searches = [...await list()]
      ..removeWhere((s) => s.name == name);
    searches.add(SavedSearch(
      name: name.trim(),
      query: query.trim(),
      createdAt: DateTime.now().toUtc().toIso8601String(),
    ));
    searches.sort((a, b) => a.name.compareTo(b.name));
    await _write(searches);
  }

  Future<bool> delete(String name) async {
    final searches = [...await list()];
    final remaining =
        searches.where((s) => s.name != name).toList();
    if (remaining.length == searches.length) return false;
    await _write(remaining);
    return true;
  }

  /// Resolves a saved search by name (exact, case-insensitive).
  Future<SavedSearch?> resolve(String name) async {
    final needle = name.toLowerCase();
    for (final search in await list()) {
      if (search.name.toLowerCase() == needle) return search;
    }
    return null;
  }

  Future<void> _write(List<SavedSearch> searches) async {
    final file = File(_path);
    await file.parent.create(recursive: true);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(
        const JsonEncoder.withIndent('  ').convert(
            [for (final s in searches) s.toJson()]));
    if (await file.exists()) await file.delete();
    await tmp.rename(file.path);
  }
}

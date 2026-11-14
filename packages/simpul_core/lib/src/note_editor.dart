import 'dart:io';

import 'package:path/path.dart' as p;

import 'note_parser.dart';

import 'vault_index.dart' show resolveTarget;
import 'vault_scanner.dart';

/// One wikilink in the editor together with its resolution result (FR-21).
class EditorLink {
  const EditorLink(this.link, this.resolvedPath);

  final ParsedLink link;

  /// Vault-relative path when the target resolves; null means unresolved
  /// ("tautan rusak").
  final String? resolvedPath;

  bool get resolved => resolvedPath != null;
}

/// In-memory link lookup over a vault snapshot (FR-12, FR-20, FR-21):
/// completion candidates, target resolution (basename, path, or alias) and
/// the backlink map. Rebuilt whenever the editor loads a vault.
class VaultLinkResolver {
  VaultLinkResolver(List<ScannedNote> notes) : _notes = List.of(notes) {
    for (final note in _notes) {
      final stripped = note.path.replaceAll(RegExp(r'\.md$'), '');
      _byPath[note.path] = note.path;
      _byPath[stripped] = note.path;
      _byBasename.putIfAbsent(_basename(stripped), () => note.path);
      for (final alias in note.parsed.aliases) {
        _byAlias.putIfAbsent(alias.toLowerCase(), () => note.path);
      }
      final title = note.parsed.title;
      if (title.isNotEmpty) {
        _byAlias.putIfAbsent(title.toLowerCase(), () => note.path);
      }
    }
    for (final note in _notes) {
      for (final link in note.parsed.links) {
        if (link.target.isEmpty) continue;
        final resolved = resolve(link.target);
        if (resolved == null) continue;
        _backlinks.putIfAbsent(resolved, () => <String>[]).add(note.path);
      }
    }
    for (final sources in _backlinks.values) {
      sources.sort();
    }
  }

  final List<ScannedNote> _notes;
  final Map<String, String> _byPath = {};
  final Map<String, String> _byBasename = {};
  final Map<String, String> _byAlias = {};
  final Map<String, List<String>> _backlinks = {};

  List<ScannedNote> get notes => _notes;

  String _basename(String path) =>
      path.split(RegExp(r'[\\/]')).last;

  /// Resolves a link target the same way the index does, plus titles and
  /// aliases (FR-22).
  String? resolve(String target) {
    if (target.isEmpty) return null;
    return resolveTarget(target, _byBasename, _byPath) ??
        _byAlias[target.toLowerCase()];
  }

  /// Backlink sources per vault-relative note path, sorted (FR-20).
  Map<String, List<String>> get backlinks => _backlinks;

  /// Wikilink completion candidates for [token], matched against basenames,
  /// titles and aliases; closest matches first (FR-12).
  List<({String path, String label})> completions(
    String token, {
    int limit = 8,
  }) {
    final needle = token.toLowerCase();
    final scored = <(int, String, String)>{};
    for (final note in _notes) {
      final stripped = note.path.replaceAll(RegExp(r'\.md$'), '');
      final base = _basename(stripped);
      final title = note.parsed.title;
      var score = -1;
      if (needle.isEmpty) {
        score = 3;
      } else if (base.toLowerCase().startsWith(needle)) {
        score = 0;
      } else if (title.toLowerCase().startsWith(needle)) {
        score = 1;
      } else if (base.toLowerCase().contains(needle) ||
          title.toLowerCase().contains(needle) ||
          stripped.toLowerCase().contains(needle)) {
        score = 2;
      } else {
        final aliasHit = note.parsed.aliases.any(
          (a) => a.toLowerCase().startsWith(needle),
        );
        if (aliasHit) score = 2;
      }
      if (score < 0) continue;
      scored.add((score, stripped, title.isEmpty ? base : title));
    }
    final ordered = scored.toList()
      ..sort((a, b) {
        final byScore = a.$1.compareTo(b.$1);
        if (byScore != 0) return byScore;
        return a.$2.compareTo(b.$2);
      });
    return [
      for (final (_, path, label) in ordered.take(limit))
        (path: path, label: label),
    ];
  }
}

/// Markdown note editor state: undo/redo (FR-16), atomic save (FR-17),
/// wikilink completion (FR-12) and outgoing-link status (FR-21).
///
/// Pure Dart and UI-free so both the Flutter client and CLI hosts share it.
class NoteEditor {
  NoteEditor({required this.vaultDir, this.resolver});

  final String vaultDir;
  final VaultLinkResolver? resolver;

  String _path = '';
  String _saved = '';
  final List<String> _undo = [];
  final List<String> _redo = [];
  String _text = '';

  static const int _maxUndoEntries = 500;

  /// Vault-relative path of the open note; empty when nothing is open.
  String get path => _path;

  String get text => _text;
  bool get dirty => _text != _saved;
  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;

  /// Loads a note from the vault. Throws [FileSystemException] when missing.
  Future<void> load(String relativePath) async {
    final file = File(p.join(vaultDir, relativePath));
    _text = await file.readAsString();
    _path = relativePath;
    _saved = _text;
    _undo.clear();
    _redo.clear();
  }

  /// Replaces the whole text (one undo entry per call, FR-16).
  set text(String value) {
    if (value == _text) return;
    _undo.add(_text);
    if (_undo.length > _maxUndoEntries) _undo.removeAt(0);
    _redo.clear();
    _text = value;
  }

  /// Applies [mutation] to the current text as a single undoable step.
  void edit(String Function(String current) mutation) => text = mutation(_text);

  bool undo() {
    if (_undo.isEmpty) return false;
    _redo.add(_text);
    _text = _undo.removeLast();
    return true;
  }

  bool redo() {
    if (_redo.isEmpty) return false;
    _undo.add(_text);
    _text = _redo.removeLast();
    return true;
  }

  /// Atomic save (FR-17): write to `<name>.md.tmp` in the same folder, then
  /// rename over the target so a crash never leaves a half-written note.
  Future<void> save() async {
    final target = File(p.join(vaultDir, _path));
    await target.parent.create(recursive: true);
    final tmp = File('${target.path}.tmp');
    await tmp.writeAsString(_text, flush: true);
    if (await target.exists()) {
      await target.delete();
    }
    await tmp.rename(target.path);
    _saved = _text;
  }

  /// Inserts a wikilink for [target] (with optional [alias]) at [offset].
  /// Returns the new cursor offset.
  int insertWikilink(int offset, String target, {String? alias}) {
    final link = alias == null || alias.isEmpty
        ? '[[$target]]'
        : '[[$target|$alias]]';
    final before = _text.substring(0, offset.clamp(0, _text.length));
    final after = _text.substring(offset.clamp(0, _text.length));
    text = '$before$link$after';
    return before.length + link.length;
  }

  /// Outgoing links of the current text, classified resolved/unresolved.
  List<EditorLink> links() {
    final parsed = NoteParser.parse(_path, _text);
    final resolver = this.resolver;
    return [
      for (final link in parsed.links)
        EditorLink(link, resolver?.resolve(link.target)),
    ];
  }

  /// Backlink sources of the open note from the vault snapshot (FR-20).
  List<String> backlinks() {
    final resolver = this.resolver;
    if (resolver == null || _path.isEmpty) return const [];
    final stripped = _path.replaceAll(RegExp(r'\.md$'), '');
    return resolver.backlinks[_path] ??
        resolver.backlinks[stripped] ??
        const [];
  }
}

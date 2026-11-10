import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import 'tiko_config.dart';

/// Atomic config revisions with history/diff/rollback (PRD).
class ConfigStore {
  ConfigStore({required this.configPath, required this.revisionsDir});

  final String configPath;
  final String revisionsDir;

  Future<void> ensure() async {
    await Directory(revisionsDir).create(recursive: true);
  }

  Future<int> currentRevision() async {
    final f = File(p.join(revisionsDir, 'HEAD'));
    if (!await f.exists()) return 0;
    return int.tryParse((await f.readAsString()).trim()) ?? 0;
  }

  Future<List<Map<String, dynamic>>> history({int limit = 30}) async {
    await ensure();
    final dir = Directory(revisionsDir);
    if (!await dir.exists()) return [];
    final metas = <Map<String, dynamic>>[];
    await for (final e in dir.list()) {
      if (e is File && e.path.endsWith('.meta.json')) {
        try {
          metas.add(jsonDecode(await e.readAsString()) as Map<String, dynamic>);
        } catch (_) {}
      }
    }
    metas.sort((a, b) => ((b['revision'] as num?) ?? 0).compareTo((a['revision'] as num?) ?? 0));
    return metas.take(limit).toList();
  }

  Future<({int revision, List<ConfigIssue> issues})> setPath(
    String dottedPath,
    String value, {
    String actor = 'cli',
  }) async {
    await ensure();
    final raw = await File(configPath).readAsString();
    final root = _convert(loadYaml(raw));
    if (root is! Map) {
      return const (revision: 0, issues: [ConfigIssue('config', 'root bukan map')]);
    }
    final map = Map<String, dynamic>.from(root);
    _setNested(map, dottedPath.split('.'), _parseValue(value));
    return _commit(map, actor: actor, note: 'set $dottedPath');
  }

  Future<({int revision, List<ConfigIssue> issues})> writeFull(
    String yamlContent, {
    String actor = 'cli',
    String note = 'write',
  }) async {
    await ensure();
    final root = _convert(loadYaml(yamlContent));
    if (root is! Map) {
      return const (revision: 0, issues: [ConfigIssue('config', 'invalid yaml')]);
    }
    return _commit(Map<String, dynamic>.from(root), actor: actor, note: note);
  }

  Future<({int revision, List<ConfigIssue> issues})> _commit(
    Map<String, dynamic> map, {
    required String actor,
    required String note,
  }) async {
    final yamlOut = _toYaml(map);
    final tmp = File('$configPath.set.tmp');
    await tmp.writeAsString(yamlOut);
    final (_, issues) = TikoConfig.load(tmp.path);
    if (issues.any((i) => i.fatal)) {
      try {
        await tmp.delete();
      } catch (_) {}
      return (revision: await currentRevision(), issues: issues);
    }
    final rev = (await currentRevision()) + 1;
    await File(p.join(revisionsDir, 'r$rev.yaml')).writeAsString(yamlOut);
    await File(p.join(revisionsDir, 'r$rev.meta.json')).writeAsString(jsonEncode({
      'revision': rev,
      'actor': actor,
      'note': note,
      'at': DateTime.now().toUtc().toIso8601String(),
      'parent': rev - 1,
    }));
    if (await File(configPath).exists()) {
      await File(configPath).copy('$configPath.bak');
    }
    await tmp.rename(configPath);
    await File(p.join(revisionsDir, 'HEAD')).writeAsString('$rev');
    return (revision: rev, issues: issues);
  }

  Future<String> diff({int? revision}) async {
    final rev = revision ?? await currentRevision();
    if (rev <= 0) return '(belum ada revisi)';
    final b = await File(p.join(revisionsDir, 'r$rev.yaml')).readAsString();
    final prevPath = p.join(revisionsDir, 'r${rev - 1}.yaml');
    final a = await File(prevPath).exists() ? await File(prevPath).readAsString() : '';
    return '--- r${rev - 1}\n+++ r$rev\n${_lineDiff(a, b)}';
  }

  Future<({int revision, List<ConfigIssue> issues})> rollback(int toRevision) async {
    final f = File(p.join(revisionsDir, 'r$toRevision.yaml'));
    if (!await f.exists()) {
      return (
        revision: await currentRevision(),
        issues: [ConfigIssue('revision', 'r$toRevision tidak ada')],
      );
    }
    final content = await f.readAsString();
    final root = _convert(loadYaml(content));
    return _commit(
      Map<String, dynamic>.from(root as Map),
      actor: 'rollback',
      note: 'rollback to r$toRevision',
    );
  }

  dynamic _convert(dynamic y) {
    if (y is YamlMap) {
      return {for (final e in y.entries) e.key.toString(): _convert(e.value)};
    }
    if (y is YamlList) return y.map(_convert).toList();
    return y;
  }

  void _setNested(Map map, List<String> parts, dynamic value) {
    var cur = map;
    for (var i = 0; i < parts.length - 1; i++) {
      final next = cur[parts[i]];
      if (next is Map) {
        cur = next;
      } else {
        final m = <String, dynamic>{};
        cur[parts[i]] = m;
        cur = m;
      }
    }
    cur[parts.last] = value;
  }

  dynamic _parseValue(String v) {
    if (v == 'true') return true;
    if (v == 'false') return false;
    final n = num.tryParse(v);
    if (n != null) return n;
    if (v.startsWith('[') && v.endsWith(']')) {
      return v
          .substring(1, v.length - 1)
          .split(',')
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toList();
    }
    return v;
  }

  String _toYaml(Map map) {
    final buf = StringBuffer();
    String quote(String value) =>
        '"${value.replaceAll('\\', '\\\\').replaceAll('"', '\\"').replaceAll('\n', '\\n').replaceAll('\r', '\\r').replaceAll('\t', '\\t')}"';

    void write(dynamic node, int indent) {
      final pad = '  ' * indent;
      if (node is Map) {
        for (final e in node.entries) {
          final k = e.key;
          final v = e.value;
          if (v is Map) {
            buf.writeln('$pad$k:');
            write(v, indent + 1);
          } else if (v is List) {
            if (v.isEmpty) {
              buf.writeln('$pad$k: []');
            } else {
              buf.writeln('$pad$k:');
              for (final item in v) {
                if (item is Map || item is List) {
                  buf.writeln('$pad  -');
                  write(item, indent + 2);
                } else if (item is String) {
                  buf.writeln('$pad  - ${quote(item)}');
                } else {
                  buf.writeln('$pad  - $item');
                }
              }
            }
          } else if (v is String) {
            buf.writeln('$pad$k: ${quote(v)}');
          } else {
            buf.writeln('$pad$k: $v');
          }
        }
      }
    }
    write(map, 0);
    return buf.toString();
  }

  String _lineDiff(String a, String b) {
    final al = a.split('\n');
    final bl = b.split('\n');
    final out = StringBuffer();
    final max = al.length > bl.length ? al.length : bl.length;
    for (var i = 0; i < max; i++) {
      final x = i < al.length ? al[i] : '';
      final y = i < bl.length ? bl[i] : '';
      if (x != y) {
        if (x.isNotEmpty) out.writeln('- $x');
        if (y.isNotEmpty) out.writeln('+ $y');
      }
    }
    return out.isEmpty ? '(identical)\n' : out.toString();
  }
}

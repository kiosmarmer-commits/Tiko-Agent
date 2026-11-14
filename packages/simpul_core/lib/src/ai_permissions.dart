import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Access decision for AI tooling over a note (DIF-04, AI-42): `allow`
/// (izin penuh), `ask` (tanya dulu — headless tooling treats this as refused),
/// `deny` (tolak — never appears in results, context, or prompt logs).
enum AiAccessDecision { allow, ask, deny }

AiAccessDecision _parseDecision(Object? value) {
  switch (value?.toString().toLowerCase()) {
    case 'izin' || 'izin penuh' || 'allow':
      return AiAccessDecision.allow;
    case 'tanya' || 'tanya dulu' || 'ask':
      return AiAccessDecision.ask;
    case 'tolak' || 'deny':
      return AiAccessDecision.deny;
    default:
      throw FormatException('status akses AI tidak dikenal: $value');
  }
}

AiAccessDecision _mostRestructive(AiAccessDecision a, AiAccessDecision b) =>
    AiAccessDecision.values.indexOf(a) >= AiAccessDecision.values.indexOf(b)
        ? a
        : b;

/// Thrown when the policy refuses an AI access (DIF-04). The bridge turns
/// this into an `isError` tool result plus an audit line; the refused note
/// never reaches the model.
class AiAccessDenied implements Exception {
  AiAccessDenied(this.decision, String path)
      : message = decision == AiAccessDecision.deny
            ? 'akses ditolak kebijakan AI: $path (status tolak)'
            : 'akses butuh persetujuan manusia: $path (status tanya dulu)';

  final AiAccessDecision decision;
  final String message;

  @override
  String toString() => message;
}

/// AI access policy over a vault (DIF-04, AI-42). Rules are configured in
/// `<vault>/.simpul/ai-permissions.json`:
///
/// ```json
/// {
///   "default": "izin",
///   "folders": {"rahasia": "tolak", "draft": "tanya"},
///   "notes": {"rahasia/kunci.md": "tolak"},
///   "tags": {"pribadi": "tolak"}
/// }
/// ```
///
/// The effective decision is the most restrictive among every matching layer
/// (default, longest folder prefix, exact note, any matching tag). When the
/// config file is absent the policy is off (AI is optional, AI-01); a corrupt
/// config fails closed via [AiAccessPolicy.denyAll].
class AiAccessPolicy {
  AiAccessPolicy({
    this.defaultValue = AiAccessDecision.allow,
    Map<String, AiAccessDecision>? folders,
    Map<String, AiAccessDecision>? notes,
    Map<String, AiAccessDecision>? tags,
  })  : folders = Map.of(folders ?? const {}),
        notes = Map.of(notes ?? const {}),
        tags = Map.of(tags ?? const {});

  final AiAccessDecision defaultValue;
  final Map<String, AiAccessDecision> folders;
  final Map<String, AiAccessDecision> notes;
  final Map<String, AiAccessDecision> tags;

  static const fileName = 'ai-permissions.json';

  /// Loads the policy for [vaultDir]; an absent file means the policy is off.
  /// A corrupt or invalid file throws — callers must fall back to
  /// [AiAccessPolicy.denyAll] (fail-closed).
  static AiAccessPolicy load(String vaultDir) {
    final file = File(p.join(vaultDir, '.simpul', fileName));
    if (!file.existsSync()) return AiAccessPolicy();
    Map<String, Object?> decoded;
    try {
      decoded = (jsonDecode(file.readAsStringSync()) as Map)
          .cast<String, Object?>();
    } on FormatException catch (e) {
      throw FormatException('$fileName rusak: ${e.message}');
    }
    return AiAccessPolicy(
      defaultValue: decoded.containsKey('default')
          ? _parseDecision(decoded['default'])
          : AiAccessDecision.allow,
      folders: _ruleMap(decoded['folders']),
      notes: _ruleMap(decoded['notes']),
      tags: _ruleMap(decoded['tags']),
    );
  }

  static Map<String, AiAccessDecision> _ruleMap(Object? raw) {
    if (raw == null) return {};
    if (raw is! Map) {
      throw const FormatException('aturan izin AI harus berupa objek');
    }
    return {
      for (final entry in raw.entries)
        entry.key.toString().toLowerCase(): _parseDecision(entry.value),
    };
  }

  /// Everything refused — the fail-closed fallback for a corrupt config.
  AiAccessPolicy.denyAll()
      : defaultValue = AiAccessDecision.deny,
        folders = const {},
        notes = const {},
        tags = const {};

  bool get isOff =>
      defaultValue == AiAccessDecision.allow &&
      folders.isEmpty &&
      notes.isEmpty &&
      tags.isEmpty;

  /// Effective decision for [notePath]: the most restrictive among the
  /// default, the LONGEST matching folder prefix (a more specific folder
  /// overrides a broader one), the exact note rule, and any matching tag
  /// ([tags] use nested-tag ancestor matching, Obsidian-style).
  AiAccessDecision decide(String notePath, {Set<String> tags = const {}}) {
    var decision = defaultValue;
    final normalized = notePath.toLowerCase();
    final exact = notes[normalized];
    if (exact != null) {
      decision = _mostRestructive(decision, exact);
    }
    String? bestFolder;
    AiAccessDecision? bestFolderRule;
    folders.forEach((folder, rule) {
      if (normalized == folder || normalized.startsWith('$folder/')) {
        if (bestFolder == null || folder.length > bestFolder!.length) {
          bestFolder = folder;
          bestFolderRule = rule;
        }
      }
    });
    if (bestFolderRule != null) {
      decision = _mostRestructive(decision, bestFolderRule!);
    }
    for (final tag in tags) {
      final normalizedTag = tag.toLowerCase();
      this.tags.forEach((ruleTag, rule) {
        if (normalizedTag == ruleTag ||
            normalizedTag.startsWith('$ruleTag/')) {
          decision = _mostRestructive(decision, rule);
        }
      });
    }
    return decision;
  }
}

/// Audit trail for AI access (AI-43): one JSON line per tool call in
/// `<vault>/.simpul/ai-audit.jsonl` — who (agent), what (tool + target),
/// when, and whether the policy allowed it. Content itself is never logged.
class AiAuditLogger {
  AiAuditLogger(this.vaultDir);

  final String vaultDir;

  String get _path => p.join(vaultDir, '.simpul', 'ai-audit.jsonl');

  void log({
    required String tool,
    required String target,
    required AiAccessDecision decision,
    Map<String, Object?> detail = const {},
  }) {
    final entry = jsonEncode({
      'ts': DateTime.now().toUtc().toIso8601String(),
      'tool': tool,
      'target': target,
      'decision': decision.name,
      if (detail.isNotEmpty) 'detail': detail,
    });
    final file = File(_path);
    file.parent.createSync(recursive: true);
    file.writeAsStringSync('$entry\n', mode: FileMode.append, flush: true);
  }
}

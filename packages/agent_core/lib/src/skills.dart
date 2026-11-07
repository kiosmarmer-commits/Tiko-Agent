import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Skill lifecycle (AGD-06 SL-01/02).
enum SkillStatus { draft, trial, approved, retired }

class Skill {
  Skill({
    required this.slug,
    required this.name,
    required this.description,
    required this.body,
    this.triggers = const [],
    this.tools = const [],
    this.version = 1,
    this.status = SkillStatus.draft,
    this.uses = 0,
    this.successes = 0,
    this.path,
    this.sha256,
    this.goldenScore = 0,
    this.goldenTotal = 0,
    this.approvedBy,
  });

  final String slug;
  final String name;
  final String description;
  final String body;
  final List<String> triggers;
  final List<String> tools;
  final int version;
  SkillStatus status;
  int uses;
  int successes;
  final String? path;
  final String? sha256;
  double goldenScore;
  double goldenTotal;
  String? approvedBy;

  double get successRate => uses == 0 ? 0 : successes / uses;

  String get promptDescription =>
      '$name: $description (status=${status.name}, triggers=${triggers.join(", ")})';

  Map<String, dynamic> toJson() => {
    'slug': slug,
    'name': name,
    'description': description,
    'triggers': triggers,
    'tools': tools,
    'version': version,
    'status': status.name,
    'uses': uses,
    'successes': successes,
    'golden_score': goldenScore,
    'golden_total': goldenTotal,
    'approved_by': approvedBy,
  };
}

/// Parse agentskills-style SKILL.md with YAML-like frontmatter.
class SkillParser {
  static Skill? parse(String content, {String? slug, String? path}) {
    final trimmed = content.trim();
    if (!trimmed.startsWith('---')) return null;
    final end = trimmed.indexOf('\n---', 3);
    if (end < 0) return null;
    final fm = trimmed.substring(3, end).trim();
    final body = trimmed.substring(end + 4).trim();

    final meta = <String, String>{};
    for (final line in fm.split('\n')) {
      final idx = line.indexOf(':');
      if (idx <= 0) continue;
      final k = line.substring(0, idx).trim();
      final v = line.substring(idx + 1).trim();
      if ((v.startsWith('[') && v.endsWith(']')) ||
          (v.startsWith('"') && v.endsWith('"'))) {
        // keep as-is for list/string
      }
      meta[k] = v;
    }

    List<String> parseList(String? raw) {
      if (raw == null || raw.isEmpty) return [];
      raw = raw.trim();
      if (raw.startsWith('[') && raw.endsWith(']')) {
        raw = raw.substring(1, raw.length - 1);
      }
      return raw
          .split(',')
          .map((s) => s.trim().replaceAll('"', '').replaceAll("'", ''))
          .where((s) => s.isNotEmpty)
          .toList();
    }

    final name = meta['name'] ?? slug ?? 'unnamed';
    final derivedSlug =
        slug ??
        name
            .toLowerCase()
            .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
            .replaceAll(RegExp(r'^-|-$'), '');

    final status = SkillStatus.values.firstWhere(
      (s) => s.name == (meta['status'] ?? 'draft'),
      orElse: () => SkillStatus.draft,
    );

    return Skill(
      slug: derivedSlug,
      name: name,
      description: meta['description'] ?? '',
      body: body,
      triggers: parseList(meta['triggers']),
      tools: parseList(meta['tools']),
      version: int.tryParse(meta['version'] ?? '1') ?? 1,
      status: status,
      path: path,
    );
  }
}

class SkillRegistry {
  final Map<String, Skill> _skills = {};

  List<Skill> get all => _skills.values.toList();
  List<Skill> get active =>
      _skills.values.where((s) => s.status != SkillStatus.retired).toList();

  void register(Skill skill) => _skills[skill.slug] = skill;

  Skill? get(String slug) => _skills[slug];

  /// Load all skills/`<slug>`/SKILL.md.
  Future<int> loadFromDirectory(String dirPath) async {
    final dir = Directory(dirPath);
    if (!await dir.exists()) return 0;
    var n = 0;
    final root = await dir.resolveSymbolicLinks();
    await for (final entity in dir.list(followLinks: false)) {
      if (entity is! Directory) continue;
      try {
        final realDir = await entity.resolveSymbolicLinks();
        if (realDir != root && !p.isWithin(root, realDir)) continue;
        final skillFile = File(p.join(realDir, 'SKILL.md'));
        if (FileSystemEntity.typeSync(skillFile.path, followLinks: false) !=
            FileSystemEntityType.file) {
          continue;
        }
        final realFile = await skillFile.resolveSymbolicLinks();
        if (!p.isWithin(realDir, realFile)) continue;
        final info = await skillFile.stat();
        if (info.size > SkillValidator.maxBytes) continue;
        final content = await skillFile.readAsString();
        final skill = SkillParser.parse(
          content,
          slug: p.basename(entity.path),
          path: skillFile.path,
        );
        if (skill == null) continue;
        final err = SkillValidator.validate(skill);
        if (err != null) continue;
        // A YAML frontmatter status is user-editable, not an approval record.
        // Imported skills always return to draft until SkillPromotionGate has
        // run a sandboxed golden evaluation and an explicit actor approves.
        skill.status = SkillStatus.draft;
        skill.approvedBy = null;
        skill.goldenScore = 0;
        skill.goldenTotal = 0;
        register(skill);
        n++;
      } catch (_) {
        // A single unreadable/unsafe skill cannot abort startup or partially load.
      }
    }
    return n;
  }

  /// Skills whose triggers match [text] (substring, case-insensitive).
  List<Skill> match(String text) {
    final lower = text.toLowerCase();
    return active.where((s) {
      if (s.triggers.isEmpty) return false;
      return s.triggers.any((t) => lower.contains(t.toLowerCase()));
    }).toList();
  }

  void recordUse(String slug, {required bool success}) {
    final s = _skills[slug];
    if (s == null) return;
    s.uses++;
    if (success) s.successes++;
    // auto promote/retire heuristics
    // Auto-promote to approved DISABLED without SkillPromotionGate (PRD §9.5).
    // trial may stay trial until explicit approve after golden.
    if (s.status == SkillStatus.approved &&
        s.uses >= 5 &&
        s.successRate < 0.6) {
      s.status = SkillStatus.retired;
    }
  }

  /// User feedback 👍/👎 on recent skill use (stronger signal than auto metrics).
  void applyFeedback(String slug, {required bool positive}) {
    final s = _skills[slug];
    if (s == null) return;
    s.uses++;
    if (positive) {
      s.successes++;
      // Feedback is telemetry only. It never activates draft/trial skills;
      // approval is reserved for SkillPromotionGate + explicit user action.
    } else {
      if (s.status == SkillStatus.approved && s.successRate < 0.5) {
        s.status = SkillStatus.retired;
      } else if (s.status == SkillStatus.trial &&
          s.uses >= 3 &&
          s.successRate < 0.4) {
        s.status = SkillStatus.retired;
      }
    }
  }
}

/// Validator (AGD-06): frontmatter, size, no secrets, tools exist.
class SkillValidator {
  static const maxBytes = 4096;

  static final _secretPatterns = [
    RegExp(r'sk-[a-zA-Z0-9]{20,}'),
    RegExp(r'api[_-]?key\s*[:=]', caseSensitive: false),
    RegExp(r'password\s*[:=]', caseSensitive: false),
    RegExp(r'-----BEGIN [A-Z ]+PRIVATE KEY-----'),
    RegExp(r'curl\s+[^\n]*\|\s*sh', caseSensitive: false),
  ];

  /// Returns error message or null if OK.
  static String? validate(Skill skill, {Set<String>? knownTools}) {
    if (skill.name.isEmpty) return 'name kosong';
    if (skill.description.isEmpty) return 'description kosong';
    final size =
        utf8.encode(skill.body).length + utf8.encode(skill.description).length;
    if (size > maxBytes) return 'skill terlalu besar ($size > $maxBytes)';
    final blob = '${skill.description}\n${skill.body}';
    for (final p in _secretPatterns) {
      if (p.hasMatch(blob)) return 'konten mencurigakan/rahasia terdeteksi';
    }
    if (knownTools != null) {
      for (final t in skill.tools) {
        if (!knownTools.contains(t)) return 'tool tidak dikenal: $t';
      }
    }
    return null;
  }
}

/// Generate draft skill markdown from a turn transcript (SL-01).
class SkillDraftBuilder {
  static String build({
    required String name,
    required String description,
    required List<String> triggers,
    required List<String> tools,
    required List<String> steps,
    List<String> failures = const [],
  }) {
    final slug = name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-');
    final buf = StringBuffer();
    buf.writeln('---');
    buf.writeln('name: $name');
    buf.writeln('description: $description');
    buf.writeln('triggers: [${triggers.map((t) => '"$t"').join(', ')}]');
    buf.writeln('tools: [${tools.join(', ')}]');
    buf.writeln('version: 1');
    buf.writeln('status: draft');
    buf.writeln('---');
    buf.writeln();
    buf.writeln('## Langkah');
    for (var i = 0; i < steps.length; i++) {
      buf.writeln('${i + 1}. ${steps[i]}');
    }
    if (failures.isNotEmpty) {
      buf.writeln();
      buf.writeln('## Kegagalan umum');
      for (final f in failures) {
        buf.writeln('- $f');
      }
    }
    buf.writeln();
    buf.writeln('<!-- generated slug: $slug -->');
    return buf.toString();
  }

  /// Persist draft under skills/`<slug>`/SKILL.md if valid.
  static Future<Skill?> saveDraft(
    String markdown, {
    required String skillsDir,
    Set<String>? knownTools,
  }) async {
    final skill = SkillParser.parse(markdown);
    if (skill == null) return null;
    final err = SkillValidator.validate(skill, knownTools: knownTools);
    if (err != null) return null;
    final dir = Directory(p.join(skillsDir, skill.slug));
    await dir.create(recursive: true);
    final file = File(p.join(dir.path, 'SKILL.md'));
    await file.writeAsString(markdown);
    return SkillParser.parse(markdown, path: file.path);
  }
}

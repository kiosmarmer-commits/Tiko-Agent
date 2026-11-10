import 'package:yaml/yaml.dart';

import 'skills.dart';

/// agentskills.io open-standard compatibility (Hermes-style skills).
///
/// The standard defines a portable `SKILL.md`: YAML frontmatter with
/// required `name` (lowercase-hyphen, ≤64 chars) and `description`
/// (≤1024 chars), optional `license`, `allowed-tools` (list), and a free
/// `metadata` map, followed by markdown instructions.
///
/// [AgentSkillManifest] parses and validates the frontmatter;
/// [AgentSkillConverter] converts between the standard format and Tiko's
/// native `Skill` so standard skills can be installed and Tiko skills
/// can be exported for the Skills Hub.

class AgentSkillManifest {
  const AgentSkillManifest({
    required this.name,
    required this.description,
    this.license,
    this.allowedTools = const [],
    this.metadata = const {},
  });

  final String name;
  final String description;
  final String? license;
  final List<String> allowedTools;
  final Map<String, dynamic> metadata;

  static final RegExp _namePattern = RegExp(r'^[a-z0-9][a-z0-9-]*$');

  bool get isValid => validate().isEmpty;

  /// Validation errors per the agentskills.io spec.
  List<String> validate() {
    final errors = <String>[];
    if (name.isEmpty) {
      errors.add('name is required');
    } else if (name.length > 64) {
      errors.add('name must be at most 64 characters');
    } else if (!_namePattern.hasMatch(name)) {
      errors.add('name must match [a-z0-9][a-z0-9-]*');
    }
    if (description.isEmpty) {
      errors.add('description is required');
    } else if (description.length > 1024) {
      errors.add('description must be at most 1024 characters');
    }
    return errors;
  }

  Map<String, dynamic> toFrontmatter() => {
        'name': name,
        'description': description,
        if (license != null) 'license': license,
        if (allowedTools.isNotEmpty) 'allowed-tools': allowedTools,
        if (metadata.isNotEmpty) 'metadata': metadata,
      };

  /// Serializes to a full SKILL.md document with [body].
  String toMarkdown(String body) {
    final buffer = StringBuffer('---\n');
    buffer.writeln('name: $name');
    buffer.writeln('description: ${_quoteIfNeeded(description)}');
    if (license != null) buffer.writeln('license: $license');
    if (allowedTools.isNotEmpty) {
      buffer.writeln('allowed-tools:');
      for (final tool in allowedTools) {
        buffer.writeln('  - $tool');
      }
    }
    if (metadata.isNotEmpty) {
      buffer.writeln('metadata:');
      for (final entry in metadata.entries) {
        buffer.writeln('  ${entry.key}: ${entry.value}');
      }
    }
    buffer
      ..writeln('---')
      ..writeln()
      ..write(body.trim());
    return buffer.toString();
  }

  /// Parses SKILL.md content. Returns the manifest (possibly invalid —
  /// check [validate]) and the markdown body after the frontmatter.
  static ({AgentSkillManifest manifest, String body, List<String> errors})
      parse(String content) {
    final errors = <String>[];
    final trimmed = content.trimLeft();
    if (!trimmed.startsWith('---')) {
      return (
        manifest: const AgentSkillManifest(name: '', description: ''),
        body: content,
        errors: ['missing YAML frontmatter (must start with ---)'],
      );
    }
    final end = trimmed.indexOf('\n---', 3);
    if (end < 0) {
      return (
        manifest: const AgentSkillManifest(name: '', description: ''),
        body: content,
        errors: ['frontmatter is not closed with ---'],
      );
    }
    final yamlText = trimmed.substring(3, end).trim();
    final body = trimmed.substring(end + 4).trim();
    dynamic doc;
    try {
      doc = loadYaml(yamlText);
    } catch (e) {
      return (
        manifest: const AgentSkillManifest(name: '', description: ''),
        body: body,
        errors: ['invalid YAML: $e'],
      );
    }
    if (doc is! YamlMap) {
      return (
        manifest: const AgentSkillManifest(name: '', description: ''),
        body: body,
        errors: ['frontmatter must be a YAML mapping'],
      );
    }
    final name = doc['name']?.toString() ?? '';
    final description = doc['description']?.toString() ?? '';
    final manifest = AgentSkillManifest(
      name: name,
      description: description,
      license: doc['license']?.toString(),
      allowedTools: [
        if (doc['allowed-tools'] is YamlList)
          for (final t in doc['allowed-tools'] as YamlList) t.toString(),
      ],
      metadata: doc['metadata'] is YamlMap
          ? Map<String, dynamic>.from(
              (doc['metadata'] as YamlMap).cast<String, dynamic>())
          : const {},
    );
    errors.addAll(manifest.validate());
    return (manifest: manifest, body: body, errors: errors);
  }

  static String _quoteIfNeeded(String value) =>
      value.contains(':') || value.contains('#') || value.contains("'")
          ? "'${value.replaceAll("'", "''")}'"
          : value;
}

/// Converts between agentskills.io SKILL.md and Tiko's native [Skill].
class AgentSkillConverter {
  const AgentSkillConverter();

  /// Builds a Tiko [Skill] from a standard manifest + body. The standard
  /// `allowed-tools` maps to Tiko's `tools`; `metadata.triggers` (list)
  /// maps to Tiko's triggers. Status starts at trial until approved.
  Skill toTikoSkill(AgentSkillManifest manifest, String body,
      {String? path}) {
    final triggers = [
      for (final t in manifest.metadata['triggers'] as List<dynamic>? ?? [])
        t.toString(),
    ];
    return Skill(
      slug: manifest.name,
      name: manifest.name,
      description: manifest.description,
      body: body,
      triggers: triggers,
      tools: manifest.allowedTools,
      status: SkillStatus.trial,
      path: path,
    );
  }

  /// Exports a Tiko [Skill] to SKILL.md content. Tiko triggers/tools are
  /// preserved via `metadata.triggers` and `allowed-tools`.
  String toSkillMarkdown(Skill skill) {
    final manifest = AgentSkillManifest(
      name: skill.slug,
      description: skill.description,
      allowedTools: skill.tools,
      metadata: {
        'triggers': skill.triggers,
        'tiko_version': skill.version,
        'tiko_status': skill.status.name,
      },
    );
    return manifest.toMarkdown(skill.body);
  }
}

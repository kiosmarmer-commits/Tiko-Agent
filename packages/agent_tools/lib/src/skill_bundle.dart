import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_core/agent_core.dart';
import 'package:path/path.dart' as p;

/// Represents a skill bundle that groups multiple skills under a single command.
class SkillBundle {
  SkillBundle({
    required this.name,
    this.description = '',
    this.skills = const [],
    this.instruction = '',
    this.metadata = const {},
  });

  final String name;
  final String description;
  final List<String> skills;
  final String instruction;
  final Map<String, dynamic> metadata;

  String get slug => _slugify(name);

  Map<String, dynamic> toJson() => {
        'name': name,
        'description': description,
        'skills': skills,
        if (instruction.isNotEmpty) 'instruction': instruction,
        'metadata': metadata,
      };

  factory SkillBundle.fromJson(Map<String, dynamic> json) {
    return SkillBundle(
      name: json['name'] as String? ?? '',
      description: json['description'] as String? ?? '',
      skills: (json['skills'] as List<dynamic>? ?? [])
          .map((e) => e.toString())
          .toList(),
      instruction: json['instruction'] as String? ?? '',
      metadata: json['metadata'] as Map<String, dynamic>? ?? {},
    );
  }

  /// Validates the bundle.
  bool validate() {
    if (name.isEmpty) return false;
    if (skills.isEmpty) return false;
    return true;
  }

  static String _slugify(String name) {
    return name
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
  }
}

/// Manages skill bundles.
class SkillBundleManager {
  SkillBundleManager({
    required this.skillRegistry,
    required this.bundlesDirectory,
    this.maxBundles = 100,
  });

  final SkillRegistry skillRegistry;
  final String bundlesDirectory;
  final int maxBundles;

  final Map<String, SkillBundle> _bundles = {};

  /// Initializes the bundle manager.
  Future<void> initialize() async {
    final dir = Directory(bundlesDirectory);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }

    await _loadBundles();
  }

  /// Loads bundles from the bundles directory.
  Future<void> _loadBundles() async {
    final dir = Directory(bundlesDirectory);
    if (!await dir.exists()) return;

    await for (final entity in dir.list()) {
      if (entity is! File || !entity.path.endsWith('.yaml') && 
          !entity.path.endsWith('.yml')) continue;

      try {
        final content = await entity.readAsString();
        final yaml = _parseYaml(content);
        final bundle = SkillBundle.fromJson(yaml);
        if (bundle.validate()) {
          _bundles[bundle.slug] = bundle;
        }
      } catch (e) {
        // Skip invalid bundle files
        continue;
      }
    }
  }

  /// Parses YAML content (simplified parser for basic YAML).
  Map<String, dynamic> _parseYaml(String content) {
    // This is a simplified YAML parser for basic skill bundle files
    // In production, you'd want to use a proper YAML parser
    
    final result = <String, dynamic>{};
    final lines = content.split('\n');
    String? currentKey;
    StringBuffer? currentValue;
    int indentLevel = 0;

    for (final line in lines) {
      final trimmed = line.trim();
      
      if (trimmed.isEmpty || trimmed.startsWith('#')) continue;

      final indent = line.length - line.trimLeft().length;

      if (indent <= indentLevel) {
        // End of current value
        if (currentKey != null && currentValue != null) {
          result[currentKey] = currentValue.toString().trim();
          currentKey = null;
          currentValue = null;
        }
        indentLevel = indent;
      }

      if (indent == 0) {
        // Top-level key
        final parts = trimmed.split(':').map((p) => p.trim()).toList();
        if (parts.length >= 2) {
          currentKey = parts[0];
          currentValue = StringBuffer(parts.sublist(1).join(':'));
        }
      } else if (currentKey != null && currentValue != null) {
        // Continuation of current value
        currentValue.write('\n$trimmed');
      }
    }

    // Add the last value
    if (currentKey != null && currentValue != null) {
      result[currentKey] = currentValue.toString().trim();
    }

    return result;
  }

  /// Creates a new skill bundle.
  Future<SkillBundle> create({
    required String name,
    String description = '',
    List<String> skills = const [],
    String instruction = '',
    Map<String, dynamic> metadata = const {},
  }) async {
    final bundle = SkillBundle(
      name: name,
      description: description,
      skills: skills,
      instruction: instruction,
      metadata: metadata,
    );

    if (!bundle.validate()) {
      throw ArgumentError('Invalid skill bundle');
    }

    // Check if skills exist
    for (final skillSlug in skills) {
      if (skillRegistry.get(skillSlug) == null) {
        throw ArgumentError('Skill not found: $skillSlug');
      }
    }

    // Save bundle
    await _saveBundle(bundle);

    // Add to cache
    _bundles[bundle.slug] = bundle;

    return bundle;
  }

  /// Saves a bundle to disk.
  Future<void> _saveBundle(SkillBundle bundle) async {
    final dir = Directory(bundlesDirectory);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }

    final file = File(p.join(bundlesDirectory, '${bundle.slug}.yaml'));
    await file.writeAsString(_toYaml(bundle));
  }

  /// Converts a bundle to YAML format.
  String _toYaml(SkillBundle bundle) {
    final lines = <String>[];
    
    lines.add('name: ${bundle.name}');
    lines.add('description: "${bundle.description}"');
    lines.add('skills:');
    for (final skill in bundle.skills) {
      lines.add('  - $skill');
    }
    if (bundle.instruction.isNotEmpty) {
      lines.add('instruction: |');
      for (final line in bundle.instruction.split('\n')) {
        lines.add('  $line');
      }
    }
    
    return lines.join('\n');
  }

  /// Gets a bundle by name or slug.
  SkillBundle? get(String nameOrSlug) {
    // Try exact match by slug
    if (_bundles.containsKey(nameOrSlug)) {
      return _bundles[nameOrSlug];
    }

    // Try match by name
    final lower = nameOrSlug.toLowerCase();
    for (final bundle in _bundles.values) {
      if (bundle.name.toLowerCase() == lower || bundle.slug == lower) {
        return bundle;
      }
    }

    return null;
  }

  /// Lists all bundles.
  List<SkillBundle> list() {
    return _bundles.values.toList();
  }

  /// Deletes a bundle.
  Future<void> delete(String nameOrSlug) async {
    final bundle = get(nameOrSlug);
    if (bundle == null) {
      throw ArgumentError('Bundle not found: $nameOrSlug');
    }

    // Delete from disk
    final file = File(p.join(bundlesDirectory, '${bundle.slug}.yaml'));
    if (await file.exists()) {
      await file.delete();
    }

    // Remove from cache
    _bundles.remove(bundle.slug);
  }

  /// Updates a bundle.
  Future<SkillBundle> update({
    required String nameOrSlug,
    String? name,
    String? description,
    List<String>? skills,
    String? instruction,
    Map<String, dynamic>? metadata,
  }) async {
    final existing = get(nameOrSlug);
    if (existing == null) {
      throw ArgumentError('Bundle not found: $nameOrSlug');
    }

    final bundle = SkillBundle(
      name: name ?? existing.name,
      description: description ?? existing.description,
      skills: skills ?? existing.skills,
      instruction: instruction ?? existing.instruction,
      metadata: metadata ?? existing.metadata,
    );

    if (!bundle.validate()) {
      throw ArgumentError('Invalid skill bundle');
    }

    // Check if skills exist
    for (final skillSlug in bundle.skills) {
      if (skillRegistry.get(skillSlug) == null) {
        throw ArgumentError('Skill not found: $skillSlug');
      }
    }

    // Delete old bundle file
    final oldFile = File(p.join(bundlesDirectory, '${existing.slug}.yaml'));
    if (await oldFile.exists()) {
      await oldFile.delete();
    }

    // Save new bundle
    await _saveBundle(bundle);

    // Update cache
    _bundles.remove(existing.slug);
    _bundles[bundle.slug] = bundle;

    return bundle;
  }

  /// Reloads all bundles from disk.
  Future<void> reload() async {
    _bundles.clear();
    await _loadBundles();
  }

  /// Gets the list of skills in a bundle that are available.
  List<String> getAvailableSkills(String nameOrSlug) {
    final bundle = get(nameOrSlug);
    if (bundle == null) return [];

    return bundle.skills.where((slug) => skillRegistry.get(slug) != null).toList();
  }

  /// Gets the list of skills in a bundle that are missing.
  List<String> getMissingSkills(String nameOrSlug) {
    final bundle = get(nameOrSlug);
    if (bundle == null) return [];

    return bundle.skills.where((slug) => skillRegistry.get(slug) == null).toList();
  }

  /// Executes a bundle by loading all its skills.
  Future<List<Skill>> execute(String nameOrSlug) async {
    final bundle = get(nameOrSlug);
    if (bundle == null) {
      throw ArgumentError('Bundle not found: $nameOrSlug');
    }

    final skills = <Skill>[];
    
    for (final skillSlug in bundle.skills) {
      final skill = skillRegistry.get(skillSlug);
      if (skill != null) {
        skills.add(skill);
      }
    }

    return skills;
  }

  /// Gets statistics about bundles.
  Map<String, dynamic> getStatistics() {
    return {
      'totalBundles': _bundles.length,
      'maxBundles': maxBundles,
      'bundlesDirectory': bundlesDirectory,
    };
  }
}

/// Tool that allows creating and managing skill bundles.
class SkillBundleTool implements Tool {
  SkillBundleTool(this.bundleManager);

  final SkillBundleManager bundleManager;

  String get name => 'skill_bundle';

  String get description =>
      'Manage skill bundles - group multiple skills under a single command.';

  @override
  ToolSpec get spec => ToolSpec(
        name: name,
        description: description,
        inputSchema: {
          'type': 'object',
          'properties': {
            'action': {
              'type': 'string',
              'enum': [
                'create',
                'delete',
                'list',
                'get',
                'update',
                'execute',
              ],
              'description': 'The action to perform',
            },
            'name': {
              'type': 'string',
              'description': 'Bundle name (for create, delete, get, update)',
            },
            'description': {
              'type': 'string',
              'description': 'Bundle description (for create, update)',
            },
            'skills': {
              'type': 'array',
              'items': {'type': 'string'},
              'description': 'List of skill slugs (for create, update)',
            },
            'instruction': {
              'type': 'string',
              'description': 'Bundle instruction (for create, update)',
            },
          },
          'required': ['action'],
        },
        parallelSafe: true,
      );

  @override
  Future<ToolResult> run(Map<String, dynamic> args, ToolContext ctx) async {
    final sw = Stopwatch()..start();
    final content = await execute(args);
    return ToolResult(
      callId: '',
      content: content,
      durationMs: sw.elapsedMilliseconds,
    );
  }

  Future<String> execute(Map<String, dynamic> arguments) async {
    try {
      final action = arguments['action'] as String?;
      
      if (action == null) {
        return jsonEncode({
          'success': false,
          'error': 'action is required',
        });
      }

      final result = await _executeAction(action, arguments);
      
      return jsonEncode({
        'success': true,
        'result': result,
      });
    } catch (e) {
      return jsonEncode({
        'success': false,
        'error': e.toString(),
      });
    }
  }

  Future<Map<String, dynamic>> _executeAction(
    String action,
    Map<String, dynamic> arguments,
  ) async {
    switch (action) {
      case 'create':
        final name = arguments['name'] as String?;
        final description = arguments['description'] as String? ?? '';
        final skills = (arguments['skills'] as List<dynamic>? ?? [])
            .map((e) => e.toString())
            .toList();
        final instruction = arguments['instruction'] as String? ?? '';

        if (name == null) throw ArgumentError('name is required');
        if (skills.isEmpty) throw ArgumentError('skills is required');

        final bundle = await bundleManager.create(
          name: name,
          description: description,
          skills: skills,
          instruction: instruction,
        );
        
        return {
          'bundle': bundle.toJson(),
          'message': 'Bundle created successfully',
        };

      case 'delete':
        final name = arguments['name'] as String?;
        if (name == null) throw ArgumentError('name is required');
        
        await bundleManager.delete(name);
        
        return {
          'message': 'Bundle deleted successfully',
        };

      case 'list':
        final bundles = bundleManager.list();
        
        return {
          'bundles': bundles.map((b) => b.toJson()).toList(),
          'count': bundles.length,
        };

      case 'get':
        final name = arguments['name'] as String?;
        if (name == null) throw ArgumentError('name is required');
        
        final bundle = bundleManager.get(name);
        if (bundle == null) throw ArgumentError('Bundle not found: $name');
        
        return {
          'bundle': bundle.toJson(),
        };

      case 'update':
        final name = arguments['name'] as String?;
        if (name == null) throw ArgumentError('name is required');
        
        final description = arguments['description'] as String?;
        final skills = (arguments['skills'] as List<dynamic>?)
            ?.map((e) => e.toString())
            .toList();
        final instruction = arguments['instruction'] as String?;
        
        final bundle = await bundleManager.update(
          nameOrSlug: name,
          description: description,
          skills: skills,
          instruction: instruction,
        );
        
        return {
          'bundle': bundle.toJson(),
          'message': 'Bundle updated successfully',
        };

      case 'execute':
        final name = arguments['name'] as String?;
        if (name == null) throw ArgumentError('name is required');
        
        final skills = await bundleManager.execute(name);
        
        return {
          'skills': skills.map((s) => s.toJson()).toList(),
          'count': skills.length,
        };

      default:
        throw ArgumentError('Unknown action: $action');
    }
  }

  Future<void> close() async {
    // Nothing to close
  }
}

/// CLI interface for skill bundles.
class SkillBundleCli {
  SkillBundleCli(this.bundleManager);

  final SkillBundleManager bundleManager;

  /// Creates a new skill bundle.
  Future<String> create({
    required String name,
    String description = '',
    List<String> skills = const [],
    String instruction = '',
  }) async {
    try {
      final bundle = await bundleManager.create(
        name: name,
        description: description,
        skills: skills,
        instruction: instruction,
      );
      return 'Created bundle ${bundle.slug}: $name';
    } catch (e) {
      return 'Error: ${e.toString()}';
    }
  }

  /// Deletes a skill bundle.
  Future<String> delete(String name) async {
    try {
      await bundleManager.delete(name);
      return 'Deleted bundle: $name';
    } catch (e) {
      return 'Error: ${e.toString()}';
    }
  }

  /// Lists all skill bundles.
  Future<String> list() async {
    final bundles = bundleManager.list();
    
    if (bundles.isEmpty) {
      return 'No skill bundles found.';
    }

    final buffer = StringBuffer();
    buffer.writeln('Available skill bundles:');
    buffer.writeln('');

    for (final bundle in bundles) {
      buffer.writeln('Name: ${bundle.name} (${bundle.slug})');
      buffer.writeln('  Description: ${bundle.description}');
      buffer.writeln('  Skills: ${bundle.skills.length}');
      buffer.writeln('');
    }

    return buffer.toString();
  }

  /// Gets details of a specific bundle.
  Future<String> get(String name) async {
    final bundle = bundleManager.get(name);
    
    if (bundle == null) {
      return 'Bundle not found: $name';
    }

    final buffer = StringBuffer();
    buffer.writeln('Bundle: ${bundle.name}');
    buffer.writeln('Slug: ${bundle.slug}');
    buffer.writeln('Description: ${bundle.description}');
    buffer.writeln('');
    buffer.writeln('Skills:');
    for (final skill in bundle.skills) {
      buffer.writeln('  - $skill');
    }
    if (bundle.instruction.isNotEmpty) {
      buffer.writeln('');
      buffer.writeln('Instruction:');
      buffer.writeln(bundle.instruction);
    }

    return buffer.toString();
  }

  /// Updates a skill bundle.
  Future<String> update({
    required String name,
    String? description,
    List<String>? skills,
    String? instruction,
  }) async {
    try {
      final bundle = await bundleManager.update(
        nameOrSlug: name,
        description: description,
        skills: skills,
        instruction: instruction,
      );
      return 'Updated bundle ${bundle.slug}';
    } catch (e) {
      return 'Error: ${e.toString()}';
    }
  }

  /// Reloads all skill bundles.
  Future<String> reload() async {
    try {
      await bundleManager.reload();
      return 'Reloaded ${bundleManager.list().length} skill bundles';
    } catch (e) {
      return 'Error: ${e.toString()}';
    }
  }

  /// Executes a skill bundle.
  Future<String> execute(String name) async {
    try {
      final skills = await bundleManager.execute(name);
      return 'Executed bundle $name: loaded ${skills.length} skills';
    } catch (e) {
      return 'Error: ${e.toString()}';
    }
  }

  /// Gets statistics about skill bundles.
  Future<String> stats() async {
    final stats = bundleManager.getStatistics();
    return 'Skill Bundle Statistics:\n${jsonEncode(stats)}';
  }
}

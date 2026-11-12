import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'skills.dart';

/// Configuration for progressive skill loading.
class ProgressiveSkillConfig {
  const ProgressiveSkillConfig({
    this.enabled = true,
    this.level0MaxTokens = 3000,
    this.level1MaxTokens = 10000,
    this.loadLevel1OnMatch = true,
    this.loadReferencesOnDemand = true,
    this.maxConcurrentLoads = 5,
    this.cacheSize = 100,
  });

  final bool enabled;
  final int level0MaxTokens;
  final int level1MaxTokens;
  final bool loadLevel1OnMatch;
  final bool loadReferencesOnDemand;
  final int maxConcurrentLoads;
  final int cacheSize;
}

/// Represents a skill at different disclosure levels.
class ProgressiveSkill {
  ProgressiveSkill({
    required this.slug,
    required this.name,
    required this.description,
    required this.category,
    required this.tags,
    this.level0Content,
    this.level1Content,
    this.references = const {},
    this.metadata = const {},
  });

  final String slug;
  final String name;
  final String description;
  final String category;
  final List<String> tags;
  final String? level0Content; // Metadata only
  final String? level1Content; // Full content without references
  final Map<String, String> references; // Reference files
  final Map<String, dynamic> metadata;

  /// Estimates the token count for level 0 (metadata only).
  int get level0TokenCount {
    // Rough estimation: name + description + tags
    return (name.length + description.length + tags.join(' ').length) ~/ 4;
  }

  /// Estimates the token count for level 1 (full content).
  int get level1TokenCount {
    if (level1Content == null) return level0TokenCount;
    return level1Content!.length ~/ 4;
  }

  /// Gets the content at a specific level.
  String? getContent(int level) {
    switch (level) {
      case 0:
        return level0Content;
      case 1:
        return level1Content;
      case 2:
        // Level 2 would include references
        // For now, return level 1
        return level1Content;
      default:
        return null;
    }
  }

  /// Gets a reference file content.
  String? getReference(String refPath) {
    return references[refPath];
  }

  Map<String, dynamic> toJson() => {
        'slug': slug,
        'name': name,
        'description': description,
        'category': category,
        'tags': tags,
        'metadata': metadata,
      };

  factory ProgressiveSkill.fromSkill(Skill skill, {String? level0Content}) {
    return ProgressiveSkill(
      slug: skill.slug,
      name: skill.name,
      description: skill.description,
      category: 'general',
      tags: List<String>.from(skill.triggers),
      level0Content: level0Content,
      level1Content: skill.body,
      metadata: {
        'status': skill.status.name,
        'version': skill.version,
        'uses': skill.uses,
        'successes': skill.successes,
      },
    );
  }
}

/// Loads skills progressively to minimize token usage.
///
/// This implements the progressive disclosure pattern similar to Hermes Agent,
/// where skills are loaded at different levels based on need:
/// - Level 0: Metadata only (name, description, tags) - ~3k tokens
/// - Level 1: Full skill content - varies
/// - Level 2: Full content + reference files - varies
class ProgressiveSkillLoader {
  ProgressiveSkillLoader({
    required this.skillRegistry,
    required this.skillsDirectory,
    ProgressiveSkillConfig? config,
  })  : config = config ?? const ProgressiveSkillConfig(),
        _cache = LruCache<String, ProgressiveSkill>(config?.cacheSize ?? 100);

  final SkillRegistry skillRegistry;
  final String skillsDirectory;
  final ProgressiveSkillConfig config;
  final LruCache<String, ProgressiveSkill> _cache;

  final Map<String, Future<ProgressiveSkill>> _loading = {};

  /// Gets a skill at level 0 (metadata only).
  Future<ProgressiveSkill> getLevel0(String slug) async {
    if (!config.enabled) {
      // Fallback to full skill
      final skill = skillRegistry.get(slug);
      if (skill == null) throw ArgumentError('Skill not found: $slug');
      return ProgressiveSkill.fromSkill(skill);
    }

    // Check cache
    var skill = _cache.get(slug);
    if (skill != null) {
      return skill;
    }

    // Check if already loading
    if (_loading.containsKey(slug)) {
      return await _loading[slug]!;
    }

    // Load from registry
    final fullSkill = skillRegistry.get(slug);
    if (fullSkill == null) {
      throw ArgumentError('Skill not found: $slug');
    }

    // Create level 0 skill
    skill = ProgressiveSkill.fromSkill(
      fullSkill,
      level0Content: _createLevel0Content(fullSkill),
    );

    _cache.put(slug, skill);
    return skill;
  }

  /// Gets a skill at level 1 (full content).
  Future<ProgressiveSkill> getLevel1(String slug) async {
    if (!config.enabled) {
      // Fallback to full skill
      final skill = skillRegistry.get(slug);
      if (skill == null) throw ArgumentError('Skill not found: $slug');
      return ProgressiveSkill.fromSkill(skill);
    }

    // Check cache
    var skill = _cache.get(slug);
    if (skill != null && skill.level1Content != null) {
      return skill;
    }

    // Check if already loading
    if (_loading.containsKey(slug)) {
      return await _loading[slug]!;
    }

    // Load full skill
    final loadFuture = _loadFullSkill(slug);
    _loading[slug] = loadFuture;

    try {
      skill = await loadFuture;
      _cache.put(slug, skill);
      return skill;
    } finally {
      _loading.remove(slug);
    }
  }

  /// Gets a reference file for a skill.
  Future<String?> getReference(String slug, String refPath) async {
    if (!config.enabled || !config.loadReferencesOnDemand) {
      return null;
    }

    // Check cache
    final skill = _cache.get(slug);
    if (skill != null) {
      return skill.getReference(refPath);
    }

    // Load skill with references
    final fullSkill = await _loadFullSkill(slug);
    return fullSkill.getReference(refPath);
  }

  /// Loads a skill with all levels and references.
  Future<ProgressiveSkill> _loadFullSkill(String slug) async {
    final skill = skillRegistry.get(slug);
    if (skill == null) {
      throw ArgumentError('Skill not found: $slug');
    }

    // Load reference files if available
    final references = await _loadReferences(slug, skill);

    return ProgressiveSkill.fromSkill(
      skill,
      level0Content: _createLevel0Content(skill),
    )..references.addAll(references);
  }

  /// Creates level 0 content (metadata only).
  String _createLevel0Content(Skill skill) {
    return '''
---
name: ${skill.name}
description: ${skill.description}
category: general
tags: [${skill.triggers.join(', ')}]
version: ${skill.version}
status: ${skill.status.name}
triggers: [${skill.triggers.join(', ')}]
tools: [${skill.tools.join(', ')}]
---

${skill.name}

${skill.description}

Status: ${skill.status.name}
Version: ${skill.version}
''';
  }

  /// Loads reference files for a skill.
  Future<Map<String, String>> _loadReferences(String slug, Skill skill) async {
    final references = <String, String>{};

    if (skill.path == null) return references;

    final skillDir = p.dirname(skill.path!);
    final refDir = Directory(p.join(skillDir, 'references'));

    if (!await refDir.exists()) return references;

    await for (final entity in refDir.list()) {
      if (entity is! File) continue;
      
      final relativePath = p.relative(entity.path, from: skillDir);
      
      try {
        final content = await entity.readAsString();
        references[relativePath] = content;
      } catch (e) {
        // Skip files that can't be read
        continue;
      }
    }

    return references;
  }

  /// Lists all skills at level 0.
  Future<List<ProgressiveSkill>> listLevel0() async {
    if (!config.enabled) {
      // Fallback to full skills
      return skillRegistry.all
          .map((s) => ProgressiveSkill.fromSkill(s))
          .toList();
    }

    final skills = <ProgressiveSkill>[];
    
    for (final skill in skillRegistry.all) {
      skills.add(ProgressiveSkill.fromSkill(
        skill,
        level0Content: _createLevel0Content(skill),
      ));
    }

    return skills;
  }

  /// Searches skills by query at level 0.
  Future<List<ProgressiveSkill>> searchLevel0(String query) async {
    final allSkills = await listLevel0();
    final lowerQuery = query.toLowerCase();

    return allSkills.where((skill) {
      return skill.name.toLowerCase().contains(lowerQuery) ||
          skill.description.toLowerCase().contains(lowerQuery) ||
          skill.tags.any((tag) => tag.toLowerCase().contains(lowerQuery)) ||
          skill.category.toLowerCase().contains(lowerQuery);
    }).toList();
  }

  /// Matches skills by triggers at level 0.
  Future<List<ProgressiveSkill>> matchLevel0(String text) async {
    final matchedSkills = skillRegistry.match(text);
    
    return matchedSkills.map((skill) => ProgressiveSkill.fromSkill(
      skill,
      level0Content: _createLevel0Content(skill),
    )).toList();
  }

  /// Gets the token count for a list of skills at level 0.
  int getLevel0TokenCount(List<ProgressiveSkill> skills) {
    return skills.fold<int>(0, (sum, skill) => sum + skill.level0TokenCount);
  }

  /// Gets the token count for a list of skills at level 1.
  int getLevel1TokenCount(List<ProgressiveSkill> skills) {
    return skills.fold<int>(0, (sum, skill) => sum + skill.level1TokenCount);
  }

  /// Clears the cache.
  void clearCache() {
    _cache.clear();
  }

  /// Gets statistics about the loader.
  Map<String, dynamic> getStatistics() {
    return {
      'enabled': config.enabled,
      'cacheSize': _cache.size,
      'cacheCapacity': _cache.capacity,
      'loadingCount': _loading.length,
      'totalSkills': skillRegistry.all.length,
    };
  }
}

/// Simple LRU cache implementation.
class LruCache<K, V> {
  LruCache(this.capacity);

  final int capacity;
  final Map<K, V> _map = <K, V>{};

  int get size => _map.length;

  V? get(K key) {
    final value = _map[key];
    if (value != null) {
      // Move to end (most recently used)
      _map.remove(key);
      _map[key] = value;
    }
    return value;
  }

  void put(K key, V value) {
    if (_map.containsKey(key)) {
      _map.remove(key);
    } else if (_map.length >= capacity) {
      // Remove oldest (first)
      _map.remove(_map.keys.first);
    }
    _map[key] = value;
  }

  void remove(K key) {
    _map.remove(key);
  }

  void clear() {
    _map.clear();
  }

  bool containsKey(K key) => _map.containsKey(key);
}


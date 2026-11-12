import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'context_expander.dart';
import 'interfaces.dart';
import 'models.dart';

/// Context file types supported by Tiko-Agent (similar to Hermes Agent)
class ContextFileType {
  static const String hermes = '.hermes.md';
  static const String agents = 'AGENTS.md';
  static const String soul = 'SOUL.md';
  static const String claud = 'CLAUDE.md';
  static const String cursorRules = '.cursorrules';
  static const String cursorSettings = '.cursor/settings.json';

  /// All supported context file types
  static const List<String> all = [
    hermes,
    agents,
    soul,
    claud,
    cursorRules,
    cursorSettings,
  ];

  /// Check if a filename is a context file
  static bool isContextFile(String filename) {
    return all.any((type) => filename.endsWith(type));
  }
}

/// A context file that provides additional context for the agent
class ContextFile {
  const ContextFile({
    required this.path,
    required this.type,
    required this.content,
    this.priority = 0,
  });

  final String path;
  final String type;
  final String content;
  final int priority;

  /// Get the role for this context file in the prompt
  String get role {
    switch (type) {
      case ContextFileType.soul:
        return 'system';
      case ContextFileType.hermes:
      case ContextFileType.agents:
      case ContextFileType.claud:
        return 'system';
      case ContextFileType.cursorRules:
      case ContextFileType.cursorSettings:
        return 'system';
      default:
        return 'system';
    }
  }

  /// Get the content type for this context file
  String get contentType {
    switch (type) {
      case ContextFileType.soul:
        return 'personality';
      case ContextFileType.hermes:
        return 'hermes';
      case ContextFileType.agents:
        return 'agents';
      case ContextFileType.claud:
        return 'claude';
      case ContextFileType.cursorRules:
        return 'cursor_rules';
      case ContextFileType.cursorSettings:
        return 'cursor_settings';
      default:
        return 'unknown';
    }
  }

  Map<String, dynamic> toJson() => {
        'path': path,
        'type': type,
        'priority': priority,
      };
}

/// Configuration for context file loading
class ContextFilesConfig {
  const ContextFilesConfig({
    this.enabled = true,
    this.searchPaths = const ['.', '..'],
    this.maxDepth = 3,
    this.maxFileSize = 1024 * 1024, // 1MB
    this.loadTypes = const [
      ContextFileType.hermes,
      ContextFileType.agents,
      ContextFileType.soul,
      ContextFileType.claud,
    ],
    this.priorityOrder = const [
      ContextFileType.soul,
      ContextFileType.hermes,
      ContextFileType.agents,
      ContextFileType.claud,
      ContextFileType.cursorRules,
      ContextFileType.cursorSettings,
    ],
  });

  final bool enabled;
  final List<String> searchPaths;
  final int maxDepth;
  final int maxFileSize;
  final List<String> loadTypes;
  final List<String> priorityOrder;

  /// Check if a type should be loaded
  bool shouldLoad(String type) => loadTypes.contains(type);

  /// Get priority for a type
  int getPriority(String type) {
    final index = priorityOrder.indexOf(type);
    return index >= 0 ? index : priorityOrder.length;
  }
}

/// Manages loading and caching of context files
class ContextFilesManager {
  ContextFilesManager({
    ContextFilesConfig? config,
    String? workingDirectory,
  })  : config = config ?? const ContextFilesConfig(),
        workingDirectory = workingDirectory ?? Directory.current.path;

  final ContextFilesConfig config;
  final String workingDirectory;

  final Map<String, ContextFile> _loadedFiles = {};
  final Map<String, DateTime> _lastModified = {};

  /// Load all context files from the working directory
  Future<List<ContextFile>> loadAll() async {
    if (!config.enabled) return [];

    final contextFiles = <ContextFile>[];

    // Search in working directory and parent directories
    for (final searchPath in config.searchPaths) {
      final dir = Directory(p.join(workingDirectory, searchPath));
      if (!await dir.exists()) continue;

      // Load context files from this directory
      final files = await _loadFromDirectory(dir);
      contextFiles.addAll(files);
    }

    // Sort by priority
    contextFiles.sort((a, b) {
      final priorityA = config.getPriority(a.type);
      final priorityB = config.getPriority(b.type);
      return priorityA.compareTo(priorityB);
    });

    // Cache loaded files
    for (final file in contextFiles) {
      _loadedFiles[file.path] = file;
    }

    return contextFiles;
  }

  /// Load context files from a specific directory
  Future<List<ContextFile>> _loadFromDirectory(Directory dir) async {
    final contextFiles = <ContextFile>[];

    try {
      await for (final entity in dir.list(recursive: false)) {
        if (entity is! File) continue;

        final filename = p.basename(entity.path);
        
        // Check if this is a context file
        if (!ContextFileType.isContextFile(filename)) continue;

        // Check file size
        final size = await entity.length();
        if (size > config.maxFileSize) {
          continue;
        }

        // Check if file has changed
        final lastModified = await entity.lastModified();
        if (_lastModified.containsKey(entity.path) &&
            _lastModified[entity.path]! == lastModified) {
          // File hasn't changed, use cached version
          if (_loadedFiles.containsKey(entity.path)) {
            contextFiles.add(_loadedFiles[entity.path]!);
          }
          continue;
        }

        // Load the file
        final content = await entity.readAsString();
        final type = _getType(filename);

        // Only load if type is in loadTypes
        if (!config.shouldLoad(type)) continue;

        final contextFile = ContextFile(
          path: entity.path,
          type: type,
          content: content,
          priority: config.getPriority(type),
        );

        contextFiles.add(contextFile);
        _lastModified[entity.path] = lastModified;
      }
    } catch (e) {
      // Directory might not be accessible
    }

    return contextFiles;
  }

  /// Get the type of a context file based on its name
  String _getType(String filename) {
    if (filename.endsWith(ContextFileType.hermes)) {
      return ContextFileType.hermes;
    } else if (filename == ContextFileType.agents) {
      return ContextFileType.agents;
    } else if (filename == ContextFileType.soul) {
      return ContextFileType.soul;
    } else if (filename == ContextFileType.claud) {
      return ContextFileType.claud;
    } else if (filename == ContextFileType.cursorRules) {
      return ContextFileType.cursorRules;
    } else if (filename == ContextFileType.cursorSettings) {
      return ContextFileType.cursorSettings;
    }
    return filename;
  }

  /// Get a specific context file by type
  ContextFile? getByType(String type) {
    for (final file in _loadedFiles.values) {
      if (file.type == type) {
        return file;
      }
    }
    return null;
  }

  /// Get all loaded context files
  List<ContextFile> get loadedFiles => _loadedFiles.values.toList();

  /// Check if a context file type is loaded
  bool hasType(String type) => _loadedFiles.values.any((f) => f.type == type);

  /// Reload all context files
  Future<List<ContextFile>> reload() async {
    _loadedFiles.clear();
    _lastModified.clear();
    return await loadAll();
  }

  /// Get the system prompt from context files
  String getSystemPrompt() {
    final parts = <String>[];

    // Add SOUL.md first (highest priority)
    final soul = getByType(ContextFileType.soul);
    if (soul != null) {
      parts.add(soul.content);
    }

    // Add .hermes.md
    final hermes = getByType(ContextFileType.hermes);
    if (hermes != null) {
      parts.add(hermes.content);
    }

    // Add AGENTS.md
    final agents = getByType(ContextFileType.agents);
    if (agents != null) {
      parts.add(agents.content);
    }

    // Add CLAUDE.md
    final claud = getByType(ContextFileType.claud);
    if (claud != null) {
      parts.add(claud.content);
    }

    return parts.isNotEmpty ? parts.join('\n\n') : '';
  }

  /// Watch for changes in context files
  Stream<ContextFileChange> watch() async* {
    // In a real implementation, this would watch the filesystem
    // For now, this is a placeholder
    yield* const Stream.empty();
  }
}

/// Event for context file changes
class ContextFileChange {
  const ContextFileChange({
    required this.type,
    required this.path,
    this.oldContent,
    this.newContent,
  });

  final String type;
  final String path;
  final String? oldContent;
  final String? newContent;

  bool get isAdded => oldContent == null && newContent != null;
  bool get isRemoved => oldContent != null && newContent == null;
  bool get isModified => oldContent != null && newContent != null && oldContent != newContent;
}

/// Tool for managing context files
class ContextFilesTool implements Tool {
  ContextFilesTool(this.manager);

  final ContextFilesManager manager;

  String get name => 'context_files';

  String get description =>
      'Manage context files (SOUL.md, AGENTS.md, .hermes.md, etc.) that provide '
      'additional context and instructions for the agent.';

  @override
  ToolSpec get spec => ToolSpec(
        name: name,
        description: description,
        inputSchema: {
          'type': 'object',
          'properties': {
            'action': {
              'type': 'string',
              'enum': ['list', 'get', 'reload'],
              'description': 'The action to perform',
            },
            'type': {
              'type': 'string',
              'description': 'Context file type (for get action)',
              'enum': [
                'soul',
                'agents',
                'hermes',
                'claude',
                'cursorrules',
              ],
            },
          },
          'required': ['action'],
        },
        risk: 'low',
        parallelSafe: true,
      );

  @override
  Future<ToolResult> run(Map<String, dynamic> args, ToolContext ctx) async {
    try {
      final action = args['action'] as String? ?? 'list';

      switch (action) {
        case 'list':
          final files = manager.loadedFiles;
          final result = {
            'success': true,
            'files': files.map((f) => {
              'path': f.path,
              'type': f.type,
              'priority': f.priority,
            }).toList(),
          };
          return ToolResult(
            callId: '',
            content: jsonEncode(result),
            isError: false,
          );

        case 'get':
          final type = args['type'] as String?;
          if (type == null) {
            return ToolResult(
              callId: '',
              content: jsonEncode({
                'success': false,
                'error': 'type is required for get action',
              }),
              isError: true,
            );
          }

          final file = manager.getByType(type);
          if (file == null) {
            return ToolResult(
              callId: '',
              content: jsonEncode({
                'success': false,
                'error': 'Context file not found: $type',
              }),
              isError: true,
            );
          }

          return ToolResult(
            callId: '',
            content: jsonEncode({
              'success': true,
              'path': file.path,
              'type': file.type,
              'content': file.content,
            }),
            isError: false,
          );

        case 'reload':
          await manager.reload();
          return ToolResult(
            callId: '',
            content: jsonEncode({
              'success': true,
              'files': manager.loadedFiles.length,
            }),
            isError: false,
          );

        default:
          return ToolResult(
            callId: '',
            content: jsonEncode({
              'success': false,
              'error': 'Unknown action: $action',
            }),
            isError: true,
          );
      }
    } catch (e) {
      return ToolResult(
        callId: '',
        content: jsonEncode({
          'success': false,
          'error': e.toString(),
        }),
        isError: true,
      );
    }
  }
}

/// Context reference types
class ContextReferenceType {
  static const String file = 'file';
  static const String directory = 'dir';
  static const String url = 'url';
  static const String git = 'git';

  static bool isValid(String type) =>
      type == file || type == directory || type == url || type == git;
}

/// A context reference (e.g., @file, @dir, @url, @git)
class ContextReference {
  const ContextReference({
    required this.type,
    required this.target,
    this.lineStart,
    this.lineEnd,
    this.language,
  });

  final String type;
  final String target;
  final int? lineStart;
  final int? lineEnd;
  final String? language;

  /// Parse a reference string (e.g., "@file:path/to/file.txt")
  static ContextReference? parse(String reference) {
    // Remove whitespace
    final trimmed = reference.trim();

    // Check if it starts with @
    if (!trimmed.startsWith('@')) return null;

    // Extract type and target
    final parts = trimmed.substring(1).split(':');
    if (parts.isEmpty) return null;

    final type = parts[0].toLowerCase();
    if (!ContextReferenceType.isValid(type)) return null;

    final target = parts.length > 1 ? parts[1] : '';

    return ContextReference(
      type: type,
      target: target,
    );
  }

  /// Parse multiple references from text
  static List<ContextReference> parseAll(String text) {
    final references = <ContextReference>[];
    
    // Simple regex to find @file:path, @dir:path, @url:http://..., @git:diff
    final regex = RegExp(r'@(file|dir|url|git):([^\s]+)');
    
    for (final match in regex.allMatches(text)) {
      final type = match.group(1)!;
      final target = match.group(2)!;
      
      references.add(ContextReference(
        type: type,
        target: target,
      ));
    }

    return references;
  }

  /// Expand the reference to actual content
  Future<String> expand(ContextExpander expander) async {
    switch (type) {
      case ContextReferenceType.file:
        return await expander.expandFile(target, language: language);
      case ContextReferenceType.directory:
        return await expander.expandDirectory(target);
      case ContextReferenceType.url:
        return await expander.expandUrl(target);
      case ContextReferenceType.git:
        return await expander.expandGit(target);
      default:
        return '';
    }
  }

  @override
  String toString() => '@$type:$target';
}

/// Expanded context from references
class ExpandedContext {
  const ExpandedContext({
    required this.originalText,
    required this.expandedText,
    required this.references,
    this.hasErrors = false,
    this.errors = const [],
  });

  final String originalText;
  final String expandedText;
  final List<ContextReference> references;
  final bool hasErrors;
  final List<String> errors;
}

/// Enhanced context expander with support for context files
class EnhancedContextExpander extends ContextExpander {
  EnhancedContextExpander({
    required super.workspaceRoot,
    this.maxFileSize = 1024 * 1024, // 1MB
    this.maxDirectoryFiles = 100,
    this.maxUrlSize = 10 * 1024 * 1024, // 10MB
    this.contextFilesManager,
  });

  final int maxFileSize;
  final int maxDirectoryFiles;
  final int maxUrlSize;
  final ContextFilesManager? contextFilesManager;

  @override
  Future<String> expandFile(String path, {String? language}) async {
    // Resolve path relative to workspace
    final fullPath = p.isAbsolute(path)
        ? path
        : p.join(workspaceRoot, path);

    try {
      final file = File(fullPath);
      if (!await file.exists()) {
        return '[ERROR: File not found: $path]';
      }

      // Check file size
      final size = await file.length();
      if (size > maxFileSize) {
        return '[ERROR: File too large: $path (${size ~/ 1024}KB > ${maxFileSize ~/ 1024}KB)]';
      }

      // Read file
      final content = await file.readAsString();

      // Add language marker if specified
      if (language != null) {
        return '```$language\n$content\n```';
      }

      return content;
    } catch (e) {
      return '[ERROR: Failed to read file: $path - ${e.toString()}]';
    }
  }

  @override
  Future<String> expandDirectory(String path) async {
    // Resolve path relative to workspace
    final fullPath = p.isAbsolute(path)
        ? path
        : p.join(workspaceRoot, path);

    try {
      final dir = Directory(fullPath);
      if (!await dir.exists()) {
        return '[ERROR: Directory not found: $path]';
      }

      final buffer = StringBuffer();
      buffer.writeln('Directory: $path');
      buffer.writeln('---');

      // List files
      final entities = await dir.list().toList();
      if (entities.length > maxDirectoryFiles) {
        buffer.writeln('[WARNING: Directory has ${entities.length} files, showing first $maxDirectoryFiles]');
      }

      var count = 0;
      for (final entity in entities) {
        if (count >= maxDirectoryFiles) break;
        
        if (entity is File) {
          final size = await entity.length();
          buffer.writeln('📄 ${p.basename(entity.path)} (${size ~/ 1024}KB)');
        } else if (entity is Directory) {
          buffer.writeln('📁 ${p.basename(entity.path)}/');
        }
        
        count++;
      }

      return buffer.toString();
    } catch (e) {
      return '[ERROR: Failed to read directory: $path - ${e.toString()}]';
    }
  }

  @override
  Future<String> expandGit(String ref) async {
    // Parse git reference (e.g., "diff", "commit:hash", "branch:name")
    // This is a placeholder - actual implementation would use git commands
    return '[ERROR: Git expansion not yet implemented: $ref]';
  }

  /// Expand all references in text
  Future<ExpandedContext> expandAll(String text) async {
    // Parse references
    final references = ContextReference.parseAll(text);
    
    if (references.isEmpty) {
      return ExpandedContext(
        originalText: text,
        expandedText: text,
        references: [],
      );
    }

    // Expand each reference
    final errors = <String>[];
    String expandedText = text;

    for (final ref in references) {
      try {
        final content = await ref.expand(this);
        expandedText = expandedText.replaceFirst(ref.toString(), content);
      } catch (e) {
        errors.add('Failed to expand ${ref.toString()}: ${e.toString()}');
        expandedText = expandedText.replaceFirst(
          ref.toString(),
          '[ERROR: Failed to expand reference]',
        );
      }
    }

    return ExpandedContext(
      originalText: text,
      expandedText: expandedText,
      references: references,
      hasErrors: errors.isNotEmpty,
      errors: errors,
    );
  }

  /// Get system prompt from context files
  String getSystemPrompt() {
    if (contextFilesManager != null) {
      return contextFilesManager!.getSystemPrompt();
    }
    return '';
  }
}

/// Tool for expanding context references
class ContextReferencesTool implements Tool {
  ContextReferencesTool(this.expander);

  final EnhancedContextExpander expander;

  String get name => 'expand_references';

  String get description =>
      'Expand context references in text (e.g., @file:path, @dir:path, @url:http://...). '
      'This allows the agent to include external content in its analysis.';

  @override
  ToolSpec get spec => ToolSpec(
        name: name,
        description: description,
        inputSchema: {
          'type': 'object',
          'properties': {
            'text': {
              'type': 'string',
              'description': 'Text containing context references to expand',
            },
            'workspace': {
              'type': 'string',
              'description': 'Workspace root for relative paths',
            },
          },
          'required': ['text'],
        },
        risk: 'low',
        parallelSafe: true,
      );

  @override
  Future<ToolResult> run(Map<String, dynamic> args, ToolContext ctx) async {
    try {
      final text = args['text'] as String?;
      if (text == null || text.isEmpty) {
        return ToolResult(
          callId: '',
          content: jsonEncode({
            'success': false,
            'error': 'text is required',
          }),
          isError: true,
        );
      }

      // Update workspace if provided
      final workspace = args['workspace'] as String?;
      final currentExpander = workspace != null
          ? EnhancedContextExpander(
              workspaceRoot: workspace,
              maxFileSize: expander.maxFileSize,
              maxDirectoryFiles: expander.maxDirectoryFiles,
              maxUrlSize: expander.maxUrlSize,
            )
          : expander;

      // Expand references
      final result = await currentExpander.expandAll(text);

      return ToolResult(
        callId: '',
        content: jsonEncode({
          'success': true,
          'originalText': result.originalText,
          'expandedText': result.expandedText,
          'references': result.references.map((r) => r.toString()).toList(),
          'hasErrors': result.hasErrors,
          'errors': result.errors,
        }),
        isError: result.hasErrors,
      );
    } catch (e) {
      return ToolResult(
        callId: '',
        content: jsonEncode({
          'success': false,
          'error': e.toString(),
        }),
        isError: true,
      );
    }
  }
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Represents a checkpoint of the working directory state.
class Checkpoint {
  Checkpoint({
    required this.id,
    required this.timestamp,
    required this.description,
    required this.workingDirectory,
    required this.fileChanges,
    this.metadata = const {},
  });

  final String id;
  final DateTime timestamp;
  final String description;
  final String workingDirectory;
  final Map<String, CheckpointFile> fileChanges;
  final Map<String, dynamic> metadata;

  Map<String, dynamic> toJson() => {
        'id': id,
        'timestamp': timestamp.toIso8601String(),
        'description': description,
        'workingDirectory': workingDirectory,
        'fileChanges': fileChanges.map(
          (key, value) => MapEntry(key, value.toJson()),
        ),
        'metadata': metadata,
      };

  factory Checkpoint.fromJson(Map<String, dynamic> json) {
    return Checkpoint(
      id: json['id'] as String? ?? '',
      timestamp: DateTime.tryParse(json['timestamp'] as String? ?? '') ??
          DateTime.now(),
      description: json['description'] as String? ?? '',
      workingDirectory: json['workingDirectory'] as String? ?? '',
      fileChanges: (json['fileChanges'] as Map<String, dynamic>? ?? {})
          .map(
            (key, value) => MapEntry(
              key,
              CheckpointFile.fromJson(value as Map<String, dynamic>),
            ),
          ),
      metadata: json['metadata'] as Map<String, dynamic>? ?? {},
    );
  }
}

/// Represents a file change in a checkpoint.
class CheckpointFile {
  CheckpointFile({
    required this.path,
    required this.action,
    this.content,
    this.checksum,
    this.permissions,
    this.modifiedAt,
  });

  final String path;
  final String action; // 'create', 'modify', 'delete'
  final String? content;
  final String? checksum;
  final String? permissions;
  final DateTime? modifiedAt;

  Map<String, dynamic> toJson() => {
        'path': path,
        'action': action,
        if (content != null) 'content': content,
        if (checksum != null) 'checksum': checksum,
        if (permissions != null) 'permissions': permissions,
        if (modifiedAt != null) 'modifiedAt': modifiedAt!.toIso8601String(),
      };

  factory CheckpointFile.fromJson(Map<String, dynamic> json) {
    return CheckpointFile(
      path: json['path'] as String? ?? '',
      action: json['action'] as String? ?? 'modify',
      content: json['content'] as String?,
      checksum: json['checksum'] as String?,
      permissions: json['permissions'] as String?,
      modifiedAt: json['modifiedAt'] != null
          ? DateTime.tryParse(json['modifiedAt'] as String)
          : null,
    );
  }
}

/// Configuration for the checkpoint manager.
class CheckpointConfig {
  const CheckpointConfig({
    this.enabled = true,
    this.maxCheckpoints = 10,
    this.checkpointDirectory = '.tiko/checkpoints',
    this.autoCheckpointOnFileChange = true,
    this.autoCheckpointInterval = const Duration(minutes: 5),
    this.includePatterns = const [],
    this.excludePatterns = const ['.git', '.tiko', 'node_modules', '.dart_tool'],
  });

  final bool enabled;
  final int maxCheckpoints;
  final String checkpointDirectory;
  final bool autoCheckpointOnFileChange;
  final Duration autoCheckpointInterval;
  final List<String> includePatterns;
  final List<String> excludePatterns;
}

/// Manages checkpoints for file system changes, enabling rollback functionality.
///
/// This implements a safety net similar to Hermes Agent's checkpoint system,
/// allowing users to rollback file changes made by the agent.
class CheckpointManager {
  CheckpointManager({
    CheckpointConfig? config,
    String? workingDirectory,
  })  : config = config ?? const CheckpointConfig(),
        workingDirectory = workingDirectory ?? Directory.current.path;

  final CheckpointConfig config;
  final String workingDirectory;

  final Map<String, Checkpoint> _checkpoints = {};
  final List<Checkpoint> _checkpointHistory = [];
  bool _isMonitoring = false;
  FileSystemEntity? _watchedEntity;
  StreamSubscription<FileSystemEvent>? _watchSubscription;

  String get checkpointDirectory => p.join(workingDirectory, config.checkpointDirectory);

  /// Initializes the checkpoint manager.
  Future<void> initialize() async {
    if (!config.enabled) return;

    // Create checkpoint directory if it doesn't exist
    final dir = Directory(checkpointDirectory);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }

    // Load existing checkpoints
    await _loadCheckpoints();
  }

  /// Starts monitoring the working directory for changes.
  Future<void> startMonitoring() async {
    if (!config.enabled || _isMonitoring) return;

    _isMonitoring = true;
    
    // Watch the working directory for changes
    final dir = Directory(workingDirectory);
    _watchSubscription = dir.watch(recursive: true).listen((event) {
      if (config.autoCheckpointOnFileChange) {
        _handleFileChange(event);
      }
    });

    // Start periodic checkpoints
    _startPeriodicCheckpoints();
  }

  /// Stops monitoring the working directory.
  Future<void> stopMonitoring() async {
    _isMonitoring = false;
    await _watchSubscription?.cancel();
    _watchSubscription = null;
  }

  void _startPeriodicCheckpoints() {
    if (!config.enabled) return;

    Future.delayed(config.autoCheckpointInterval, () {
      if (_isMonitoring) {
        _createCheckpoint('Periodic checkpoint');
        _startPeriodicCheckpoints();
      }
    });
  }

  /// Creates a new checkpoint.
  Future<Checkpoint> createCheckpoint(String description) async {
    if (!config.enabled) {
      throw StateError('Checkpoint manager is disabled');
    }

    final checkpoint = Checkpoint(
      id: _generateId(),
      timestamp: DateTime.now(),
      description: description,
      workingDirectory: workingDirectory,
      fileChanges: await _captureFileChanges(),
    );

    // Save checkpoint
    await _saveCheckpoint(checkpoint);

    // Add to history
    _checkpoints[checkpoint.id] = checkpoint;
    _checkpointHistory.add(checkpoint);

    // Trim old checkpoints
    if (_checkpointHistory.length > config.maxCheckpoints) {
      final old = _checkpointHistory.removeAt(0);
      _checkpoints.remove(old.id);
      await _deleteCheckpoint(old);
    }

    return checkpoint;
  }

  /// Creates a checkpoint before making file changes.
  ///
  /// This is called automatically by tools that modify files.
  Future<Checkpoint> createPreChangeCheckpoint(String description) async {
    if (!config.enabled) {
      return Checkpoint(
        id: '',
        timestamp: DateTime.now(),
        description: description,
        workingDirectory: workingDirectory,
        fileChanges: {},
      );
    }

    return await createCheckpoint(description);
  }

  /// Rolls back to a specific checkpoint.
  Future<void> rollbackTo(String checkpointId) async {
    final checkpoint = _checkpoints[checkpointId];
    if (checkpoint == null) {
      throw ArgumentError('Checkpoint not found: $checkpointId');
    }

    // Rollback each file change
    for (final entry in checkpoint.fileChanges.entries) {
      final filePath = p.join(workingDirectory, entry.key);
      final change = entry.value;

      switch (change.action) {
        case 'create':
        case 'modify':
          // Restore the file content
          if (change.content != null) {
            final file = File(filePath);
            await file.create(recursive: true);
            await file.writeAsString(change.content);
          }
          break;
        case 'delete':
          // Restore the deleted file
          if (change.content != null) {
            final file = File(filePath);
            await file.create(recursive: true);
            await file.writeAsString(change.content);
          }
          break;
      }
    }

    // Add rollback metadata
    final rollbackCheckpoint = Checkpoint(
      id: _generateId(),
      timestamp: DateTime.now(),
      description: 'Rollback to ${checkpoint.description}',
      workingDirectory: workingDirectory,
      fileChanges: await _captureFileChanges(),
      metadata: {
        'rollbackFrom': checkpoint.id,
        'originalDescription': checkpoint.description,
      },
    );

    await _saveCheckpoint(rollbackCheckpoint);
    _checkpoints[rollbackCheckpoint.id] = rollbackCheckpoint;
    _checkpointHistory.add(rollbackCheckpoint);
  }

  /// Lists all available checkpoints.
  List<Checkpoint> listCheckpoints() {
    return _checkpointHistory.toList();
  }

  /// Gets a specific checkpoint by ID.
  Checkpoint? getCheckpoint(String id) {
    return _checkpoints[id];
  }

  /// Deletes a checkpoint.
  Future<void> deleteCheckpoint(String id) async {
    final checkpoint = _checkpoints.remove(id);
    if (checkpoint != null) {
      _checkpointHistory.remove(checkpoint);
      await _deleteCheckpoint(checkpoint);
    }
  }

  /// Clears all checkpoints.
  Future<void> clearAllCheckpoints() async {
    for (final checkpoint in _checkpoints.values) {
      await _deleteCheckpoint(checkpoint);
    }
    _checkpoints.clear();
    _checkpointHistory.clear();
  }

  /// Captures current file changes in the working directory.
  Future<Map<String, CheckpointFile>> _captureFileChanges() async {
    final changes = <String, CheckpointFile>{};
    final dir = Directory(workingDirectory);

    if (!await dir.exists()) return changes;

    await for (final entity in dir.list(recursive: true)) {
      if (entity is! File) continue;

      // Skip excluded patterns
      if (_shouldExclude(entity.path)) continue;

      // Calculate relative path
      final relativePath = p.relative(entity.path, from: workingDirectory);

      // Get file info
      final stat = await entity.stat();
      final modifiedAt = stat.modified;

      // Read content (limit size for large files)
      String? content;
      try {
        final bytes = await entity.readAsBytes();
        if (bytes.length <= 1024 * 1024) { // 1MB limit
          content = utf8.decode(bytes);
        }
      } catch (e) {
        // Skip files that can't be read
        continue;
      }

      changes[relativePath] = CheckpointFile(
        path: relativePath,
        action: 'modify',
        content: content,
        modifiedAt: modifiedAt,
      );
    }

    return changes;
  }

  bool _shouldExclude(String path) {
    final relativePath = p.relative(path, from: workingDirectory);

    for (final pattern in config.excludePatterns) {
      if (relativePath.contains(pattern) ||
          relativePath.startsWith(pattern)) {
        return true;
      }
    }

    // Include patterns (if specified)
    if (config.includePatterns.isNotEmpty) {
      bool included = false;
      for (final pattern in config.includePatterns) {
        if (relativePath.contains(pattern) ||
            relativePath.startsWith(pattern)) {
          included = true;
          break;
        }
      }
      if (!included) return true;
    }

    return false;
  }

  /// Saves a checkpoint to disk.
  Future<void> _saveCheckpoint(Checkpoint checkpoint) async {
    final dir = Directory(checkpointDirectory);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }

    final file = File(p.join(checkpointDirectory, '${checkpoint.id}.json'));
    await file.writeAsString(jsonEncode(checkpoint.toJson()));
  }

  /// Deletes a checkpoint from disk.
  Future<void> _deleteCheckpoint(Checkpoint checkpoint) async {
    final file = File(p.join(checkpointDirectory, '${checkpoint.id}.json'));
    if (await file.exists()) {
      await file.delete();
    }
  }

  /// Loads checkpoints from disk.
  Future<void> _loadCheckpoints() async {
    final dir = Directory(checkpointDirectory);
    if (!await dir.exists()) return;

    await for (final entity in dir.list()) {
      if (entity is! File || !entity.path.endsWith('.json')) continue;

      try {
        final content = await entity.readAsString();
        final json = jsonDecode(content) as Map<String, dynamic>;
        final checkpoint = Checkpoint.fromJson(json);
        _checkpoints[checkpoint.id] = checkpoint;
        _checkpointHistory.add(checkpoint);
      } catch (e) {
        // Skip corrupted checkpoint files
        continue;
      }
    }

    // Sort by timestamp
    _checkpointHistory.sort((a, b) => a.timestamp.compareTo(b.timestamp));
  }

  /// Handles file change events.
  void _handleFileChange(FileSystemEvent event) {
    // Debounce rapid file changes
    Future.delayed(const Duration(milliseconds: 500), () {
      if (_isMonitoring) {
        _createCheckpoint('Auto-checkpoint on file change');
      }
    });
  }

  /// Generates a unique checkpoint ID.
  String _generateId() {
    return 'cp_${DateTime.now().millisecondsSinceEpoch}_${_checkpoints.length + 1}';
  }

  /// Gets statistics about checkpoints.
  Map<String, dynamic> getStatistics() {
    return {
      'totalCheckpoints': _checkpoints.length,
      'maxCheckpoints': config.maxCheckpoints,
      'isMonitoring': _isMonitoring,
      'checkpointDirectory': checkpointDirectory,
      'oldestCheckpoint': _checkpointHistory.isNotEmpty
          ? _checkpointHistory.first.timestamp.toIso8601String()
          : null,
      'newestCheckpoint': _checkpointHistory.isNotEmpty
          ? _checkpointHistory.last.timestamp.toIso8601String()
          : null,
    };
  }
}

/// Extension to integrate checkpoints with file-modifying tools.
extension CheckpointToolIntegration on Tool {
  /// Creates a checkpoint before executing a file-modifying tool.
  Future<Checkpoint> createCheckpointBeforeExecute(
    CheckpointManager checkpointManager,
    String description,
  ) async {
    return await checkpointManager.createPreChangeCheckpoint(description);
  }
}

/// Tool wrapper that automatically creates checkpoints for file modifications.
class CheckpointToolWrapper implements Tool {
  CheckpointToolWrapper({
    required this.tool,
    required this.checkpointManager,
  });

  final Tool tool;
  final CheckpointManager checkpointManager;

  @override
  String get name => tool.name;

  @override
  String get description => tool.description;

  @override
  ToolSpec get spec => tool.spec;

  @override
  Future<String> execute(Map<String, dynamic> arguments) async {
    // Check if this tool modifies files
    if (_isFileModifyingTool(tool)) {
      // Create checkpoint before execution
      await checkpointManager.createPreChangeCheckpoint(
        'Before ${tool.name} execution',
      );
    }

    // Execute the tool
    return await tool.execute(arguments);
  }

  @override
  Future<void> close() async {
    await tool.close();
  }

  bool _isFileModifyingTool(Tool tool) {
    // Check if tool name or description indicates file modification
    final name = tool.name.toLowerCase();
    final description = tool.description.toLowerCase();

    const fileModifyingKeywords = [
      'write',
      'patch',
      'delete',
      'create',
      'modify',
      'edit',
      'update',
      'save',
      'file',
    ];

    return fileModifyingKeywords.any((keyword) =>
      name.contains(keyword) || description.contains(keyword),
    );
  }
}

/// Command-line interface for checkpoint management.
class CheckpointCli {
  CheckpointCli(this.checkpointManager);

  final CheckpointManager checkpointManager;

  /// Lists all checkpoints.
  Future<String> list() async {
    final checkpoints = checkpointManager.listCheckpoints();
    
    if (checkpoints.isEmpty) {
      return 'No checkpoints found.';
    }

    final buffer = StringBuffer();
    buffer.writeln('Available checkpoints:');
    buffer.writeln('');

    for (final cp in checkpoints) {
      buffer.writeln('ID: ${cp.id}');
      buffer.writeln('  Time: ${cp.timestamp}');
      buffer.writeln('  Description: ${cp.description}');
      buffer.writeln('  Files: ${cp.fileChanges.length}');
      buffer.writeln('');
    }

    return buffer.toString();
  }

  /// Rolls back to a checkpoint.
  Future<String> rollback(String checkpointId) async {
    try {
      await checkpointManager.rollbackTo(checkpointId);
      return 'Successfully rolled back to checkpoint $checkpointId';
    } catch (e) {
      return 'Error: ${e.toString()}';
    }
  }

  /// Deletes a checkpoint.
  Future<String> delete(String checkpointId) async {
    try {
      await checkpointManager.deleteCheckpoint(checkpointId);
      return 'Deleted checkpoint $checkpointId';
    } catch (e) {
      return 'Error: ${e.toString()}';
    }
  }

  /// Clears all checkpoints.
  Future<String> clear() async {
    try {
      await checkpointManager.clearAllCheckpoints();
      return 'All checkpoints cleared';
    } catch (e) {
      return 'Error: ${e.toString()}';
    }
  }

  /// Creates a manual checkpoint.
  Future<String> create(String description) async {
    try {
      final checkpoint = await checkpointManager.createCheckpoint(description);
      return 'Created checkpoint ${checkpoint.id}: $description';
    } catch (e) {
      return 'Error: ${e.toString()}';
    }
  }

  /// Gets checkpoint statistics.
  Future<String> stats() async {
    final stats = checkpointManager.getStatistics();
    return 'Checkpoint Statistics:\n${jsonEncode(stats)}';
  }
}

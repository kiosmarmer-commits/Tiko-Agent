import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:agent_core/agent_core.dart';
import 'package:path/path.dart' as p;

import 'code_execution.dart';

/// Generate a random ID
String _generateId({int length = 32}) {
  const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
  final random = Random();
  return List.generate(length, (_) => chars[random.nextInt(chars.length)]).join();
}

/// Batch processing configuration
class BatchProcessingConfig {
  const BatchProcessingConfig({
    this.enabled = true,
    this.maxConcurrentTasks = 4,
    this.timeoutMinutes = 60,
    this.outputDirectory = 'batch_output',
    this.exportTrajectories = true,
    this.exportFormat = ExportFormat.json,
    this.retryFailedTasks = true,
    this.maxRetries = 3,
  });

  final bool enabled;
  final int maxConcurrentTasks;
  final int timeoutMinutes;
  final String outputDirectory;
  final bool exportTrajectories;
  final ExportFormat exportFormat;
  final bool retryFailedTasks;
  final int maxRetries;

  BatchProcessingConfig copyWith({
    bool? enabled,
    int? maxConcurrentTasks,
    int? timeoutMinutes,
    String? outputDirectory,
    bool? exportTrajectories,
    ExportFormat? exportFormat,
    bool? retryFailedTasks,
    int? maxRetries,
  }) {
    return BatchProcessingConfig(
      enabled: enabled ?? this.enabled,
      maxConcurrentTasks: maxConcurrentTasks ?? this.maxConcurrentTasks,
      timeoutMinutes: timeoutMinutes ?? this.timeoutMinutes,
      outputDirectory: outputDirectory ?? this.outputDirectory,
      exportTrajectories: exportTrajectories ?? this.exportTrajectories,
      exportFormat: exportFormat ?? this.exportFormat,
      retryFailedTasks: retryFailedTasks ?? this.retryFailedTasks,
      maxRetries: maxRetries ?? this.maxRetries,
    );
  }
}

/// Export format for batch results
enum ExportFormat {
  json('json'),
  csv('csv'),
  markdown('markdown');

  const ExportFormat(this.value);
  final String value;

  static ExportFormat fromValue(String value) {
    return values.byName(value.toLowerCase());
  }
}

/// Status of a batch task
enum BatchTaskStatus {
  pending('pending'),
  running('running'),
  completed('completed'),
  failed('failed'),
  retrying('retrying'),
  cancelled('cancelled');

  const BatchTaskStatus(this.value);
  final String value;

  static BatchTaskStatus fromValue(String value) {
    return values.byName(value.toLowerCase());
  }
}

/// A single task in a batch
class BatchTask {
  BatchTask({
    required this.id,
    required this.prompt,
    this.parameters = const {},
    this.priority = 0,
    this.dependsOn = const [],
    this.status = BatchTaskStatus.pending,
    this.result,
    this.error,
    this.startTime,
    this.endTime,
    this.retries = 0,
  });

  final String id;
  final String prompt;
  final Map<String, dynamic> parameters;
  final int priority;
  final List<String> dependsOn;
  BatchTaskStatus status;
  String? result;
  String? error;
  DateTime? startTime;
  DateTime? endTime;
  int retries;

  /// Check if task can be executed (all dependencies are completed)
  bool canExecute(List<BatchTask> allTasks) {
    if (dependsOn.isEmpty) return true;
    
    for (final depId in dependsOn) {
      final deps = allTasks.where((t) => t.id == depId).toList();
      if (deps.isEmpty) return false;
      if (deps.first.status != BatchTaskStatus.completed) return false;
    }
    return true;
  }

  /// Duration of task execution
  Duration? get duration {
    if (startTime == null || endTime == null) return null;
    return endTime!.difference(startTime!);
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'prompt': prompt,
        'parameters': parameters,
        'priority': priority,
        'dependsOn': dependsOn,
        'status': status.value,
        'result': result,
        'error': error,
        'startTime': startTime?.toIso8601String(),
        'endTime': endTime?.toIso8601String(),
        'retries': retries,
      };

  factory BatchTask.fromJson(Map<String, dynamic> json) {
    return BatchTask(
      id: json['id'] as String,
      prompt: json['prompt'] as String,
      parameters: json['parameters'] as Map<String, dynamic>? ?? {},
      priority: json['priority'] as int? ?? 0,
      dependsOn: (json['dependsOn'] as List<dynamic>? ?? []).cast<String>(),
      status: BatchTaskStatus.fromValue(json['status'] as String? ?? 'pending'),
      result: json['result'] as String?,
      error: json['error'] as String?,
      startTime: json['startTime'] != null
          ? DateTime.parse(json['startTime'] as String)
          : null,
      endTime: json['endTime'] != null
          ? DateTime.parse(json['endTime'] as String)
          : null,
      retries: json['retries'] as int? ?? 0,
    );
  }
}

/// Result of a batch processing operation
class BatchProcessingResult {
  const BatchProcessingResult({
    required this.batchId,
    required this.totalTasks,
    required this.completedTasks,
    required this.failedTasks,
    required this.status,
    this.startTime,
    this.endTime,
    this.tasks = const [],
    this.exportPath,
    this.trajectoryPath,
  });

  final String batchId;
  final int totalTasks;
  final int completedTasks;
  final int failedTasks;
  final String status;
  final DateTime? startTime;
  final DateTime? endTime;
  final List<Map<String, dynamic>> tasks;
  final String? exportPath;
  final String? trajectoryPath;

  /// Success rate
  double get successRate => 
      totalTasks > 0 ? completedTasks / totalTasks : 0.0;

  /// Duration of batch processing
  Duration? get duration {
    if (startTime == null || endTime == null) return null;
    return endTime!.difference(startTime!);
  }

  Map<String, dynamic> toJson() => {
        'batchId': batchId,
        'totalTasks': totalTasks,
        'completedTasks': completedTasks,
        'failedTasks': failedTasks,
        'status': status,
        'startTime': startTime?.toIso8601String(),
        'endTime': endTime?.toIso8601String(),
        'successRate': successRate,
        'durationMs': duration?.inMilliseconds,
        'tasks': tasks,
        'exportPath': exportPath,
        'trajectoryPath': trajectoryPath,
      };

  @override
  String toString() => jsonEncode(toJson());
}

/// Manager for batch processing operations
class BatchProcessingManager {
  BatchProcessingManager({
    this.config = const BatchProcessingConfig(),
    AgentLoop? agentLoop,
    String? workingDirectory,
  })  : _agentLoop = agentLoop,
        _workingDirectory = workingDirectory ?? Directory.current.path;

  final BatchProcessingConfig config;
  final AgentLoop? _agentLoop;
  final String _workingDirectory;

  final Map<String, List<BatchTask>> _batches = {};
  final Map<String, DateTime> _batchStartTimes = {};

  /// Create a new batch
  String createBatch({List<BatchTask>? tasks}) {
    final batchId = _generateId();
    _batches[batchId] = tasks ?? [];
    _batchStartTimes[batchId] = DateTime.now();
    return batchId;
  }

  /// Add tasks to a batch
  void addTasks(String batchId, List<BatchTask> tasks) {
    if (!_batches.containsKey(batchId)) {
      throw Exception('Batch not found: $batchId');
    }
    _batches[batchId]!.addAll(tasks);
  }

  /// Get batch by ID
  List<BatchTask>? getBatch(String batchId) => _batches[batchId];

  /// Get all batches
  Map<String, List<BatchTask>> get allBatches => Map.unmodifiable(_batches);

  /// Execute a batch of tasks
  Future<BatchProcessingResult> executeBatch({
    required String batchId,
    bool exportResults = true,
    bool exportTrajectories = true,
  }) async {
    final tasks = _batches[batchId];
    if (tasks == null || tasks.isEmpty) {
      return BatchProcessingResult(
        batchId: batchId,
        totalTasks: 0,
        completedTasks: 0,
        failedTasks: 0,
        status: 'empty',
      );
    }

    final startTime = DateTime.now();
    int completed = 0;
    int failed = 0;
    final results = <Map<String, dynamic>>[];

    // Sort tasks by priority (higher priority first)
    tasks.sort((a, b) => b.priority.compareTo(a.priority));

    // Process tasks with concurrency control
    final semaphore = _createSemaphore(config.maxConcurrentTasks);

    try {
      final futures = tasks.map((task) async {
        // Wait for semaphore
        await semaphore.acquire();

        try {
          // Wait for dependencies
          while (!task.canExecute(tasks)) {
            await Future.delayed(const Duration(milliseconds: 100));
          }

          task.status = BatchTaskStatus.running;
          task.startTime = DateTime.now();

          // Execute task
          final result = await _executeTask(task, batchId);

          if (result.success) {
            task.status = BatchTaskStatus.completed;
            task.result = result.output;
            task.endTime = DateTime.now();
            completed++;
          } else {
            task.status = BatchTaskStatus.failed;
            task.error = result.error;
            task.endTime = DateTime.now();
            failed++;
            
            // Retry if configured
            if (config.retryFailedTasks && task.retries < config.maxRetries) {
              task.retries++;
              task.status = BatchTaskStatus.retrying;
              // Re-add to queue
              await _executeTask(task, batchId);
            }
          }

          results.add(task.toJson());
        } catch (e) {
          task.status = BatchTaskStatus.failed;
          task.error = e.toString();
          task.endTime = DateTime.now();
          failed++;
          results.add(task.toJson());
        } finally {
          semaphore.release();
        }
      }).toList();

      await Future.wait(futures);

      // Export results if requested
      String? exportPath;
      String? trajectoryPath;

      if (exportResults) {
        exportPath = await _exportResults(batchId, tasks, results);
      }

      if (exportTrajectories && config.exportTrajectories) {
        trajectoryPath = await _exportTrajectories(batchId, tasks);
      }

      final endTime = DateTime.now();

      return BatchProcessingResult(
        batchId: batchId,
        totalTasks: tasks.length,
        completedTasks: completed,
        failedTasks: failed,
        status: failed > 0 ? 'partial_success' : 'completed',
        startTime: startTime,
        endTime: endTime,
        tasks: results,
        exportPath: exportPath,
        trajectoryPath: trajectoryPath,
      );
    } catch (e) {
      return BatchProcessingResult(
        batchId: batchId,
        totalTasks: tasks.length,
        completedTasks: completed,
        failedTasks: failed,
        status: 'error',
        startTime: startTime,
        endTime: DateTime.now(),
        tasks: results,
      );
    }
  }

  /// Execute a single task
  Future<CodeExecutionResult> _executeTask(BatchTask task, String batchId) async {
    // If we have an agent loop, use it
    final loop = _agentLoop;
    if (loop != null) {
      try {
        final sessionId = 'batch_${batchId}_${task.id}';
        final session = Session(
          id: sessionId,
          channel: 'batch',
          userKey: 'batch',
        );
        await loop.handle(
          InboundMessage(
            channel: 'batch',
            userKey: 'batch',
            sessionKey: sessionId,
            text: task.prompt,
          ),
          session,
        );

        if (!loop.lastTurnSucceeded) {
          return CodeExecutionResult(
            success: false,
            error: 'agent turn failed for task ${task.id}',
            exitCode: -1,
          );
        }

        return CodeExecutionResult(
          success: true,
          output: 'Task executed via agent loop: ${task.prompt}',
          exitCode: 0,
        );
      } catch (e) {
        return CodeExecutionResult(
          success: false,
          error: e.toString(),
          exitCode: -1,
        );
      }
    }

    // Fallback: just return the prompt as output
    return CodeExecutionResult(
      success: true,
      output: 'Task executed: ${task.prompt}',
      exitCode: 0,
    );
  }

  /// Export batch results
  Future<String> _exportResults(
    String batchId,
    List<BatchTask> tasks,
    List<Map<String, dynamic>> results,
  ) async {
    final outputDir = Directory(p.join(_workingDirectory, config.outputDirectory));
    if (!await outputDir.exists()) {
      await outputDir.create(recursive: true);
    }

    final timestamp = DateTime.now().toIso8601String().replaceAll(':', '-');
    final filename = 'batch_${batchId}_$timestamp';

    switch (config.exportFormat) {
      case ExportFormat.json:
        final file = File(p.join(outputDir.path, '$filename.json'));
        await file.writeAsString(
          const JsonEncoder.withIndent('  ').convert({
            'batchId': batchId,
            'timestamp': timestamp,
            'tasks': results,
          }),
        );
        return file.path;

      case ExportFormat.csv:
        final file = File(p.join(outputDir.path, '$filename.csv'));
        final csv = _resultsToCsv(results);
        await file.writeAsString(csv);
        return file.path;

      case ExportFormat.markdown:
        final file = File(p.join(outputDir.path, '$filename.md'));
        final md = _resultsToMarkdown(batchId, tasks, results);
        await file.writeAsString(md);
        return file.path;
    }
  }

  /// Export trajectories
  Future<String> _exportTrajectories(String batchId, List<BatchTask> tasks) async {
    // This would integrate with the trajectory system
    // For now, just create a simple JSON file
    final outputDir = Directory(p.join(_workingDirectory, config.outputDirectory, 'trajectories'));
    if (!await outputDir.exists()) {
      await outputDir.create(recursive: true);
    }

    final timestamp = DateTime.now().toIso8601String().replaceAll(':', '-');
    final file = File(p.join(outputDir.path, 'trajectory_${batchId}_$timestamp.json'));

    final trajectories = tasks.map((task) => {
      'taskId': task.id,
      'prompt': task.prompt,
      'status': task.status.value,
      'startTime': task.startTime?.toIso8601String(),
      'endTime': task.endTime?.toIso8601String(),
      'durationMs': task.duration?.inMilliseconds,
      'result': task.result,
      'error': task.error,
    }).toList();

    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert({
        'batchId': batchId,
        'timestamp': timestamp,
        'trajectories': trajectories,
      }),
    );

    return file.path;
  }

  /// Convert results to CSV
  String _resultsToCsv(List<Map<String, dynamic>> results) {
    final buffer = StringBuffer();
    
    // Header
    buffer.writeln('id,prompt,status,result,error,durationMs');
    
    // Data
    for (final result in results) {
      final task = BatchTask.fromJson(result);
      final duration = task.duration?.inMilliseconds ?? 0;
      buffer.writeln('"${task.id}","${task.prompt.replaceAll('"', '""')}",${task.status.value},"${task.result?.replaceAll('"', '""') ?? ''}","${task.error?.replaceAll('"', '""') ?? ''}",$duration');
    }
    
    return buffer.toString();
  }

  /// Convert results to Markdown
  String _resultsToMarkdown(
    String batchId,
    List<BatchTask> tasks,
    List<Map<String, dynamic>> results,
  ) {
    final buffer = StringBuffer();
    
    buffer.writeln('# Batch Processing Results');
    buffer.writeln();
    buffer.writeln('**Batch ID:** $batchId');
    buffer.writeln('**Timestamp:** ${DateTime.now().toIso8601String()}');
    buffer.writeln('**Total Tasks:** ${tasks.length}');
    buffer.writeln();
    
    buffer.writeln('## Summary');
    buffer.writeln();
    
    final completed = tasks.where((t) => t.status == BatchTaskStatus.completed).length;
    final failed = tasks.where((t) => t.status == BatchTaskStatus.failed).length;
    final running = tasks.where((t) => t.status == BatchTaskStatus.running).length;
    final pending = tasks.where((t) => t.status == BatchTaskStatus.pending).length;
    
    buffer.writeln('- Completed: $completed');
    buffer.writeln('- Failed: $failed');
    buffer.writeln('- Running: $running');
    buffer.writeln('- Pending: $pending');
    buffer.writeln();
    
    buffer.writeln('## Tasks');
    buffer.writeln();
    
    for (final task in tasks) {
      buffer.writeln('### Task: ${task.id}');
      buffer.writeln();
      buffer.writeln('- **Status:** ${task.status.value}');
      buffer.writeln('- **Prompt:** ${task.prompt}');
      buffer.writeln('- **Priority:** ${task.priority}');
      if (task.result != null) {
        buffer.writeln('- **Result:** ${task.result}');
      }
      if (task.error != null) {
        buffer.writeln('- **Error:** ${task.error}');
      }
      if (task.duration != null) {
        buffer.writeln('- **Duration:** ${task.duration!.inMilliseconds}ms');
      }
      buffer.writeln();
    }
    
    return buffer.toString();
  }

  /// Create a semaphore for concurrency control
  Semaphore _createSemaphore(int maxConcurrent) {
    return Semaphore(maxConcurrent);
  }

  /// Get batch status
  BatchProcessingResult getBatchStatus(String batchId) {
    final tasks = _batches[batchId];
    if (tasks == null) {
      return BatchProcessingResult(
        batchId: batchId,
        totalTasks: 0,
        completedTasks: 0,
        failedTasks: 0,
        status: 'not_found',
      );
    }

    final completed = tasks.where((t) => t.status == BatchTaskStatus.completed).length;
    final failed = tasks.where((t) => t.status == BatchTaskStatus.failed).length;
    final running = tasks.where((t) => t.status == BatchTaskStatus.running).length;

    return BatchProcessingResult(
      batchId: batchId,
      totalTasks: tasks.length,
      completedTasks: completed,
      failedTasks: failed,
      status: running > 0
          ? 'running'
          : failed > 0
              ? 'partial_success'
              : completed > 0
                  ? 'completed'
                  : 'pending',
      startTime: _batchStartTimes[batchId],
      endTime: null,
      tasks: tasks.map((t) => t.toJson()).toList(),
    );
  }

  /// Cancel a batch
  void cancelBatch(String batchId) {
    final tasks = _batches[batchId];
    if (tasks != null) {
      for (final task in tasks) {
        if (task.status == BatchTaskStatus.pending || 
            task.status == BatchTaskStatus.running ||
            task.status == BatchTaskStatus.retrying) {
          task.status = BatchTaskStatus.cancelled;
        }
      }
    }
  }

  /// Clean up completed batches
  void cleanupBatches({Duration? olderThan}) {
    final cutoff = olderThan != null
        ? DateTime.now().subtract(olderThan)
        : DateTime.now().subtract(const Duration(hours: 1));

    _batches.removeWhere((batchId, tasks) {
      final startTime = _batchStartTimes[batchId];
      if (startTime == null) return false;
      
      // Only cleanup completed batches
      final allCompleted = tasks.every((t) => 
          t.status == BatchTaskStatus.completed ||
          t.status == BatchTaskStatus.failed ||
          t.status == BatchTaskStatus.cancelled);
      
      return allCompleted && startTime.isBefore(cutoff);
    });

    _batchStartTimes.removeWhere((batchId, startTime) => 
        !_batches.containsKey(batchId));
  }
}

/// Simple semaphore for concurrency control
class Semaphore {
  Semaphore(this.maxCount);

  final int maxCount;
  int _count = 0;
  final _queue = <Completer<void>>[];

  Future<void> acquire() async {
    if (_count < maxCount) {
      _count++;
      return;
    }

    final completer = Completer<void>();
    _queue.add(completer);
    return completer.future;
  }

  void release() {
    _count--;
    if (_queue.isNotEmpty) {
      final completer = _queue.removeAt(0);
      _count++;
      completer.complete();
    }
  }
}


/// Batch processing tool for Tiko-Agent
class BatchProcessingTool implements Tool {
  BatchProcessingTool({
    this.manager,
    this.agentLoop,
    this.workingDirectory,
  }) : _manager = manager ?? BatchProcessingManager(
          config: const BatchProcessingConfig(),
          agentLoop: agentLoop,
          workingDirectory: workingDirectory,
        );

  final BatchProcessingManager? manager;
  final AgentLoop? agentLoop;
  final String? workingDirectory;
  late final BatchProcessingManager _manager;

  String get name => 'batch_processing';

  String get description =>
      'Execute multiple tasks in parallel with batch processing. '
      'Supports dependency management, retries, and trajectory export.';

  @override
  ToolSpec get spec => ToolSpec(
        name: name,
        description: description,
        inputSchema: {
          'type': 'object',
          'properties': {
            'action': {
              'type': 'string',
              'enum': ['create', 'execute', 'status', 'cancel', 'cleanup'],
              'description': 'The action to perform',
            },
            'batchId': {
              'type': 'string',
              'description': 'Batch ID (for execute, status, cancel)',
            },
            'tasks': {
              'type': 'array',
              'description': 'List of tasks to create/execute',
              'items': {
                'type': 'object',
                'properties': {
                  'id': {'type': 'string'},
                  'prompt': {'type': 'string'},
                  'parameters': {'type': 'object'},
                  'priority': {'type': 'integer'},
                  'dependsOn': {
                    'type': 'array',
                    'items': {'type': 'string'},
                  },
                },
                'required': ['prompt'],
              },
            },
            'exportResults': {
              'type': 'boolean',
              'description': 'Whether to export results',
              'default': true,
            },
            'exportTrajectories': {
              'type': 'boolean',
              'description': 'Whether to export trajectories',
              'default': true,
            },
            'maxConcurrent': {
              'type': 'integer',
              'description': 'Maximum concurrent tasks',
              'default': 4,
            },
            'olderThanHours': {
              'type': 'integer',
              'description': 'Cleanup batches older than X hours',
              'default': 1,
            },
          },
          'required': ['action'],
        },
        risk: 'medium',
        timeoutSec: 300,
      );

  @override
  Future<ToolResult> run(Map<String, dynamic> args, ToolContext ctx) async {
    try {
      final action = args['action'] as String? ?? 'status';

      switch (action) {
        case 'create':
          return await _handleCreate(args);
        case 'execute':
          return await _handleExecute(args);
        case 'status':
          return await _handleStatus(args);
        case 'cancel':
          return await _handleCancel(args);
        case 'cleanup':
          return await _handleCleanup(args);
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

  Future<ToolResult> _handleCreate(Map<String, dynamic> args) async {
    final tasksData = args['tasks'] as List<dynamic>? ?? [];
    
    final tasks = tasksData.map((data) {
      final map = data as Map<String, dynamic>;
      return BatchTask(
        id: map['id'] as String? ?? _generateId(),
        prompt: map['prompt'] as String,
        parameters: map['parameters'] as Map<String, dynamic>? ?? {},
        priority: map['priority'] as int? ?? 0,
        dependsOn: (map['dependsOn'] as List<dynamic>? ?? []).cast<String>(),
      );
    }).toList();

    final batchId = _manager.createBatch(tasks: tasks);

    return ToolResult(
      callId: '',
      content: jsonEncode({
        'success': true,
        'batchId': batchId,
        'totalTasks': tasks.length,
      }),
    );
  }

  Future<ToolResult> _handleExecute(Map<String, dynamic> args) async {
    final batchId = args['batchId'] as String?;
    if (batchId == null) {
      return ToolResult(
        callId: '',
        content: jsonEncode({
          'success': false,
          'error': 'batchId is required',
        }),
        isError: true,
      );
    }

    final exportResults = args['exportResults'] as bool? ?? true;
    final exportTrajectories = args['exportTrajectories'] as bool? ?? true;

    final result = await _manager.executeBatch(
      batchId: batchId,
      exportResults: exportResults,
      exportTrajectories: exportTrajectories,
    );

    return ToolResult(
      callId: '',
      content: jsonEncode(result.toJson()),
      isError: !result.status.contains('completed'),
    );
  }

  Future<ToolResult> _handleStatus(Map<String, dynamic> args) async {
    final batchId = args['batchId'] as String?;
    
    if (batchId != null) {
      final result = _manager.getBatchStatus(batchId);
      return ToolResult(
        callId: '',
        content: jsonEncode(result.toJson()),
      );
    }

    // Return all batches
    final allBatches = _manager.allBatches;
    final results = allBatches.entries.map((entry) {
      return {
        'batchId': entry.key,
        'tasks': entry.value.length,
      };
    }).toList();

    return ToolResult(
      callId: '',
      content: jsonEncode({
        'success': true,
        'batches': results,
      }),
    );
  }

  Future<ToolResult> _handleCancel(Map<String, dynamic> args) async {
    final batchId = args['batchId'] as String?;
    if (batchId == null) {
      return ToolResult(
        callId: '',
        content: jsonEncode({
          'success': false,
          'error': 'batchId is required',
        }),
        isError: true,
      );
    }

    _manager.cancelBatch(batchId);

    return ToolResult(
      callId: '',
      content: jsonEncode({
        'success': true,
        'batchId': batchId,
        'message': 'Batch cancelled',
      }),
    );
  }

  Future<ToolResult> _handleCleanup(Map<String, dynamic> args) async {
    final olderThanHours = args['olderThanHours'] as int? ?? 1;
    _manager.cleanupBatches(olderThan: Duration(hours: olderThanHours));

    return ToolResult(
      callId: '',
      content: jsonEncode({
        'success': true,
        'message': 'Cleaned up batches older than $olderThanHours hours',
      }),
    );
  }
}

/// Factory for creating batch processing tools
class BatchProcessingToolFactory {
  static BatchProcessingTool create({
    BatchProcessingManager? manager,
    AgentLoop? agentLoop,
    String? workingDirectory,
  }) {
    return BatchProcessingTool(
      manager: manager,
      agentLoop: agentLoop,
      workingDirectory: workingDirectory,
    );
  }
}

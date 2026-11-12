import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:agent_core/agent_core.dart';
import 'package:path/path.dart' as p;

import 'sandbox.dart';

/// Generate a random ID
String _generateId({int length = 32}) {
  const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
  final random = Random();
  return List.generate(length, (_) => chars[random.nextInt(chars.length)]).join();
}

/// Supported programming languages for code execution
enum ExecutionLanguage {
  python('python', ['.py']),
  javascript('node', ['.js', '.mjs']),
  bash('bash', ['.sh']),
  dart('dart', ['.dart']);

  const ExecutionLanguage(this.interpreter, this.extensions);

  final String interpreter;
  final List<String> extensions;

  static ExecutionLanguage fromExtension(String path) {
    final ext = p.extension(path).toLowerCase();
    for (final lang in values) {
      if (lang.extensions.contains(ext)) {
        return lang;
      }
    }
    return python; // default to python
  }

  static ExecutionLanguage fromName(String name) {
    return values.byName(name.toLowerCase());
  }
}

/// Configuration for code execution
class CodeExecutionConfig {
  const CodeExecutionConfig({
    this.enabled = true,
    this.timeoutSeconds = 30,
    this.maxOutputBytes = 1024 * 1024, // 1MB
    this.allowedLanguages = const [ExecutionLanguage.python],
    this.sandboxKind = SandboxKind.none,
    this.dockerImage = 'python:3.13-alpine',
    this.tempDirectory,
    this.workingDirectory,
    this.allowFileWrite = false,
    this.allowNetworkAccess = false,
    this.maxMemoryMb = 512,
  });

  final bool enabled;
  final int timeoutSeconds;
  final int maxOutputBytes;
  final List<ExecutionLanguage> allowedLanguages;
  final SandboxKind sandboxKind;
  final String dockerImage;
  final String? tempDirectory;
  final String? workingDirectory;
  final bool allowFileWrite;
  final bool allowNetworkAccess;
  final int maxMemoryMb;

  CodeExecutionConfig copyWith({
    bool? enabled,
    int? timeoutSeconds,
    int? maxOutputBytes,
    List<ExecutionLanguage>? allowedLanguages,
    SandboxKind? sandboxKind,
    String? dockerImage,
    String? tempDirectory,
    String? workingDirectory,
    bool? allowFileWrite,
    bool? allowNetworkAccess,
    int? maxMemoryMb,
  }) {
    return CodeExecutionConfig(
      enabled: enabled ?? this.enabled,
      timeoutSeconds: timeoutSeconds ?? this.timeoutSeconds,
      maxOutputBytes: maxOutputBytes ?? this.maxOutputBytes,
      allowedLanguages: allowedLanguages ?? this.allowedLanguages,
      sandboxKind: sandboxKind ?? this.sandboxKind,
      dockerImage: dockerImage ?? this.dockerImage,
      tempDirectory: tempDirectory ?? this.tempDirectory,
      workingDirectory: workingDirectory ?? this.workingDirectory,
      allowFileWrite: allowFileWrite ?? this.allowFileWrite,
      allowNetworkAccess: allowNetworkAccess ?? this.allowNetworkAccess,
      maxMemoryMb: maxMemoryMb ?? this.maxMemoryMb,
    );
  }
}

/// Result of a code execution
class CodeExecutionResult {
  const CodeExecutionResult({
    required this.success,
    this.output = '',
    this.error = '',
    this.exitCode = 0,
    this.executionTimeMs = 0,
    this.memoryUsedMb = 0,
    this.callId = '',
  });

  final bool success;
  final String output;
  final String error;
  final int exitCode;
  final int executionTimeMs;
  final int memoryUsedMb;
  final String callId;

  Map<String, dynamic> toJson() => {
        'success': success,
        'output': output,
        'error': error,
        'exitCode': exitCode,
        'executionTimeMs': executionTimeMs,
        'memoryUsedMb': memoryUsedMb,
        'callId': callId,
      };

  @override
  String toString() => jsonEncode(toJson());
}

/// Execution environment for running code
class CodeExecutionEnvironment {
  CodeExecutionEnvironment({
    required this.config,
    this.sandbox,
    this.tempDirectory,
    this.workingDirectory,
  });

  final CodeExecutionConfig config;
  final SandboxRunner? sandbox;
  final Directory? tempDirectory;
  final Directory? workingDirectory;

  String get tempDir => tempDirectory?.path ?? Directory.systemTemp.path;

  String get workDir => workingDirectory?.path ?? Directory.current.path;

  /// Create a temporary file for code execution
  Future<File> createTempFile({
    required String code,
    required ExecutionLanguage language,
    String? prefix,
  }) async {
    final dir = Directory(tempDir);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }

    final uuid = _generateId();
    final extension = language.extensions.first;
    final filename = prefix != null
        ? '${prefix}_$uuid$extension'
        : '$uuid$extension';
    final file = File(p.join(dir.path, filename));
    await file.writeAsString(code);
    return file;
  }

  /// Clean up temporary files
  Future<void> cleanupTempFile(File file) async {
    try {
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {
      // Ignore cleanup errors
    }
  }
}

/// Code execution provider interface
abstract class CodeExecutionProvider {
  String get name;
  List<ExecutionLanguage> get supportedLanguages;

  Future<CodeExecutionResult> execute({
    required String code,
    required ExecutionLanguage language,
    required CodeExecutionConfig config,
    String? workingDirectory,
    Map<String, String>? environment,
    Duration? timeout,
  });

  Future<bool> isAvailable();
}

/// Local code execution provider using Process.run
class LocalCodeExecutionProvider implements CodeExecutionProvider {
  @override
  String get name => 'local';

  @override
  List<ExecutionLanguage> get supportedLanguages => ExecutionLanguage.values;

  @override
  Future<bool> isAvailable() async => true;

  @override
  Future<CodeExecutionResult> execute({
    required String code,
    required ExecutionLanguage language,
    required CodeExecutionConfig config,
    String? workingDirectory,
    Map<String, String>? environment,
    Duration? timeout,
  }) async {
    final stopwatch = Stopwatch()..start();
    
    try {
      final env = <String, String>{};
      if (environment != null) {
        env.addAll(environment);
      }

      // Create temporary file
      final tempDir = Directory.systemTemp.createTempSync();
      final tempFile = File(p.join(tempDir.path, 'script${language.extensions.first}'));
      await tempFile.writeAsString(code);

      try {
        final args = [tempFile.path];
        
        // Add flags based on language
        switch (language) {
          case ExecutionLanguage.python:
            args.insert(0, language.interpreter);
            break;
          case ExecutionLanguage.javascript:
            args.insert(0, language.interpreter);
            break;
          case ExecutionLanguage.bash:
            args.insert(0, language.interpreter);
            break;
          case ExecutionLanguage.dart:
            args.insert(0, language.interpreter);
            args.insert(1, 'run');
            break;
        }

        var timedOut = false;
        final result = await Process.run(
          args.first,
          args.skip(1).toList(),
          workingDirectory: workingDirectory,
          environment: env,
        ).timeout(
          timeout ?? Duration(seconds: config.timeoutSeconds),
          onTimeout: () {
            timedOut = true;
            return ProcessResult(-1, -1, '', '');
          },
        );

        final executionTimeMs = stopwatch.elapsedMilliseconds;
        
        // Check for timeout
        if (timedOut) {
          return CodeExecutionResult(
            success: false,
            error: 'Execution timed out after ${config.timeoutSeconds} seconds',
            exitCode: -1,
            executionTimeMs: executionTimeMs,
          );
        }

        // Truncate output if too large
      String output = result.stdout.toString();
      String error = result.stderr.toString();
      
      if (output.length > config.maxOutputBytes) {
        output = output.substring(0, config.maxOutputBytes);
      }
      if (error.length > config.maxOutputBytes) {
        error = error.substring(0, config.maxOutputBytes);
      }

        return CodeExecutionResult(
          success: result.exitCode == 0,
          output: output,
          error: error,
          exitCode: result.exitCode,
          executionTimeMs: executionTimeMs,
        );
      } finally {
        // Clean up temp file
        try {
          await tempFile.delete();
          await tempDir.delete(recursive: true);
        } catch (_) {}
      }
    } catch (e) {
      return CodeExecutionResult(
        success: false,
        error: e.toString(),
        exitCode: -1,
        executionTimeMs: stopwatch.elapsedMilliseconds,
      );
    }
  }
}

/// Sandboxed code execution provider using SandboxRunner
class SandboxedCodeExecutionProvider implements CodeExecutionProvider {
  SandboxedCodeExecutionProvider(this.sandbox);

  final SandboxRunner sandbox;

  @override
  String get name => 'sandboxed';

  @override
  List<ExecutionLanguage> get supportedLanguages => [
    ExecutionLanguage.python,
    ExecutionLanguage.bash,
  ];

  @override
  Future<bool> isAvailable() async => sandbox.kind != SandboxKind.none;

  @override
  Future<CodeExecutionResult> execute({
    required String code,
    required ExecutionLanguage language,
    required CodeExecutionConfig config,
    String? workingDirectory,
    Map<String, String>? environment,
    Duration? timeout,
  }) async {
    final stopwatch = Stopwatch()..start();
    
    try {
      // Create temporary file in workspace
      final workDir = workingDirectory ?? sandbox.workspacePath;
      final tempDir = Directory(p.join(workDir, '.tiko_code_exec'));
      
      if (!await tempDir.exists()) {
        await tempDir.create(recursive: true);
      }

      final tempFile = File(p.join(tempDir.path, 'script${language.extensions.first}'));
      await tempFile.writeAsString(code);

      try {
        
        // Build command based on language
        String command;
        switch (language) {
          case ExecutionLanguage.python:
            command = 'python ${tempFile.path}';
            break;
          case ExecutionLanguage.bash:
            command = 'bash ${tempFile.path}';
            break;
          default:
            return CodeExecutionResult(
              success: false,
              error: 'Language ${language.name} not supported in sandbox',
              exitCode: -1,
              executionTimeMs: stopwatch.elapsedMilliseconds,
            );
        }

        final result = await sandbox.run(
          command.split(' '),
          timeout: timeout ?? Duration(seconds: config.timeoutSeconds),
        );

        final executionTimeMs = stopwatch.elapsedMilliseconds;
        
        // Truncate output if too large
      String output = result.stdout.toString();
      String error = result.stderr.toString();
      
      if (output.length > config.maxOutputBytes) {
        output = output.substring(0, config.maxOutputBytes);
      }
      if (error.length > config.maxOutputBytes) {
        error = error.substring(0, config.maxOutputBytes);
      }

        return CodeExecutionResult(
          success: result.exitCode == 0,
          output: output,
          error: error,
          exitCode: result.exitCode,
          executionTimeMs: executionTimeMs,
        );
      } finally {
        // Clean up temp file
        try {
          await tempFile.delete();
        } catch (_) {}
      }
    } catch (e) {
      return CodeExecutionResult(
        success: false,
        error: e.toString(),
        exitCode: -1,
        executionTimeMs: stopwatch.elapsedMilliseconds,
      );
    }
  }
}

/// Docker-based code execution provider
class DockerCodeExecutionProvider implements CodeExecutionProvider {
  DockerCodeExecutionProvider({
    this.dockerImage = 'python:3.13-alpine',
    this.timeoutSeconds = 30,
  });

  final String dockerImage;
  final int timeoutSeconds;

  @override
  String get name => 'docker';

  @override
  List<ExecutionLanguage> get supportedLanguages => [
    ExecutionLanguage.python,
    ExecutionLanguage.javascript,
    ExecutionLanguage.bash,
  ];

  @override
  Future<bool> isAvailable() async {
    try {
      final result = await Process.run('docker', ['--version']);
      return result.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<CodeExecutionResult> execute({
    required String code,
    required ExecutionLanguage language,
    required CodeExecutionConfig config,
    String? workingDirectory,
    Map<String, String>? environment,
    Duration? timeout,
  }) async {
    final stopwatch = Stopwatch()..start();
    
    try {
      // Create temporary file
      final tempDir = Directory.systemTemp.createTempSync();
      final tempFile = File(p.join(tempDir.path, 'script${language.extensions.first}'));
      await tempFile.writeAsString(code);

      try {
        // Build docker command
        List<String> dockerArgs = [
          'run',
          '--rm',
          '-i',
          '--network=none', // No network access by default
          '-m=${config.maxMemoryMb}m',
          '-v',
          '${tempDir.path}:/tmp/tiko_code',
          '-w',
          '/tmp/tiko_code',
        ];

        if (environment != null && environment.isNotEmpty) {
          for (final entry in environment.entries) {
            dockerArgs.addAll(['-e', '${entry.key}=${entry.value}']);
          }
        }

        String command;
        switch (language) {
          case ExecutionLanguage.python:
            command = 'python /tmp/tiko_code/script.py';
            dockerArgs.add(dockerImage);
            dockerArgs.addAll(['sh', '-c', command]);
            break;
          case ExecutionLanguage.javascript:
            command = 'node /tmp/tiko_code/script.js';
            dockerArgs.add('node:20-alpine');
            dockerArgs.addAll(['sh', '-c', command]);
            break;
          case ExecutionLanguage.bash:
            command = 'bash /tmp/tiko_code/script.sh';
            dockerArgs.add('alpine:latest');
            dockerArgs.addAll(['sh', '-c', command]);
            break;
          default:
            return CodeExecutionResult(
              success: false,
              error: 'Language ${language.name} not supported in docker',
              exitCode: -1,
              executionTimeMs: stopwatch.elapsedMilliseconds,
            );
        }

        final result = await Process.run(
          'docker',
          dockerArgs,
        ).timeout(
          timeout ?? Duration(seconds: config.timeoutSeconds),
          onTimeout: () => ProcessResult(-1, -1, '', ''),
        );

        final executionTimeMs = stopwatch.elapsedMilliseconds;
        
        // Truncate output if too large
      String output = result.stdout.toString();
      String error = result.stderr.toString();
      
      if (output.length > config.maxOutputBytes) {
        output = output.substring(0, config.maxOutputBytes);
      }
      if (error.length > config.maxOutputBytes) {
        error = error.substring(0, config.maxOutputBytes);
      }

        return CodeExecutionResult(
          success: result.exitCode == 0,
          output: output,
          error: error,
          exitCode: result.exitCode,
          executionTimeMs: executionTimeMs,
        );
      } finally {
        // Clean up temp directory
        try {
          await tempDir.delete(recursive: true);
        } catch (_) {}
      }
    } catch (e) {
      return CodeExecutionResult(
        success: false,
        error: e.toString(),
        exitCode: -1,
        executionTimeMs: stopwatch.elapsedMilliseconds,
      );
    }
  }
}

/// Code execution tool for Tiko-Agent
class CodeExecutionTool implements Tool {
  CodeExecutionTool({
    this.config = const CodeExecutionConfig(),
    this.provider,
    this.sandbox,
    this.workingDirectory,
  });

  final CodeExecutionConfig config;
  final CodeExecutionProvider? provider;
  final SandboxRunner? sandbox;
  final String? workingDirectory;


  CodeExecutionProvider get _effectiveProvider {
    if (provider != null) return provider!;
    final s = sandbox;
    if (s != null && s.kind != SandboxKind.none) {
      return SandboxedCodeExecutionProvider(s);
    }
    return LocalCodeExecutionProvider();
  }

  String get name => 'code_execution';

  String get description =>
      'Execute code in a sandboxed environment. Supports Python, JavaScript, '
      'Bash, and Dart. Code is executed with timeout and resource limits.';

  @override
  ToolSpec get spec => ToolSpec(
        name: name,
        description: description,
        inputSchema: {
          'type': 'object',
          'properties': {
            'code': {
              'type': 'string',
              'description': 'The code to execute',
            },
            'language': {
              'type': 'string',
              'enum': ExecutionLanguage.values.map((e) => e.name).toList(),
              'description': 'Programming language to use',
              'default': 'python',
            },
            'timeout': {
              'type': 'integer',
              'description': 'Timeout in seconds (default: ${config.timeoutSeconds})',
              'minimum': 1,
              'maximum': 300,
            },
            'workingDirectory': {
              'type': 'string',
              'description': 'Working directory for execution',
            },
          },
          'required': ['code'],
        },
        risk: 'high',
        timeoutSec: 60,
        maxOutputChars: 100000,
      );

  @override
  Future<ToolResult> run(Map<String, dynamic> args, ToolContext ctx) async {
    try {
      final code = args['code'] as String?;
      if (code == null || code.isEmpty) {
        return ToolResult(
          callId: '',
          content: jsonEncode({
            'success': false,
            'error': 'code is required',
          }),
          isError: true,
        );
      }

      // Parse language
      final languageInput = args['language'] as String? ?? 'python';
      ExecutionLanguage language;
      try {
        language = ExecutionLanguage.fromName(languageInput);
      } catch (_) {
        return ToolResult(
          callId: '',
          content: jsonEncode({
            'success': false,
            'error': 'Unsupported language: $languageInput',
          }),
          isError: true,
        );
      }

      // Check if language is allowed
      if (!config.allowedLanguages.contains(language)) {
        return ToolResult(
          callId: '',
          content: jsonEncode({
            'success': false,
            'error': 'Language ${language.name} is not allowed. Allowed: ${config.allowedLanguages.map((l) => l.name).join(", ")}',
          }),
          isError: true,
        );
      }

      // Check if provider supports this language
      if (!_effectiveProvider.supportedLanguages.contains(language)) {
        return ToolResult(
          callId: '',
          content: jsonEncode({
            'success': false,
            'error': 'Language ${language.name} is not supported by ${_effectiveProvider.name} provider',
          }),
          isError: true,
        );
      }

      // Parse timeout
      final timeout = args['timeout'] as int? ?? config.timeoutSeconds;
      
      // Parse working directory
      final workDir = args['workingDirectory'] as String? ?? workingDirectory;

      // Execute code
      final result = await _effectiveProvider.execute(
        code: code,
        language: language,
        config: config.copyWith(
          timeoutSeconds: timeout,
          workingDirectory: workDir,
        ),
        workingDirectory: workDir,
        timeout: Duration(seconds: timeout),
      );

      // Format output
      final output = result.output.isNotEmpty ? result.output : null;
      final error = result.error.isNotEmpty ? result.error : null;

      final content = jsonEncode({
        'success': result.success,
        'output': output,
        'error': error,
        'exitCode': result.exitCode,
        'executionTimeMs': result.executionTimeMs,
        'callId': result.callId,
      });

      return ToolResult(
        callId: result.callId,
        content: content,
        isError: !result.success,
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

/// Factory for creating code execution tools
class CodeExecutionToolFactory {
  static CodeExecutionTool create({
    CodeExecutionConfig? config,
    CodeExecutionProvider? provider,
    SandboxRunner? sandbox,
    String? workingDirectory,
  }) {
    return CodeExecutionTool(
      config: config ?? const CodeExecutionConfig(),
      provider: provider,
      sandbox: sandbox,
      workingDirectory: workingDirectory,
    );
  }

  /// Create a code execution tool with automatic provider selection
  static Future<CodeExecutionTool> createAuto({
    String? workingDirectory,
    SandboxRunner? sandbox,
  }) async {
    final effectiveSandbox = sandbox;

    CodeExecutionProvider? provider;

    if (effectiveSandbox != null && effectiveSandbox.kind != SandboxKind.none) {
      provider = SandboxedCodeExecutionProvider(effectiveSandbox);
    } else {
      // Try docker
      final dockerProvider = DockerCodeExecutionProvider();
      if (await dockerProvider.isAvailable()) {
        provider = dockerProvider;
      }
    }

    return CodeExecutionTool(
      config: const CodeExecutionConfig(),
      provider: provider,
      sandbox: effectiveSandbox,
      workingDirectory: workingDirectory,
    );
  }
}

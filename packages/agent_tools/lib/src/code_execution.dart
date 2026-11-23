import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:agent_core/agent_core.dart';
import 'package:path/path.dart' as p;

import 'sandbox.dart';

/// Generate a random ID (B-11: CSPRNG)
String _generateId({int length = 32}) {
  const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
  final random = Random.secure();
  return List.generate(length, (_) => chars[random.nextInt(chars.length)]).join();
}

/// Supported programming languages for code execution (F8.3 polyglot).
///
/// Compiled languages (C / C++ / Rust) follow a two-stage model: compile
/// the single source file to a binary next to it, then run that binary.
enum ExecutionLanguage {
  python('python', ['.py'], 'python:3.13-alpine'),
  javascript('node', ['.js', '.mjs'], 'node:20-alpine'),
  bash('bash', ['.sh'], 'alpine:latest'),
  dart('dart', ['.dart'], 'dart:stable'),
  java('java', ['.java'], 'eclipse-temurin:21-alpine'),
  go('go', ['.go'], 'golang:1.23-alpine'),
  c('gcc', ['.c'], 'gcc:14-bookworm'),
  cpp('g++', ['.cpp', '.cc'], 'gcc:14-bookworm'),
  rust('rustc', ['.rs'], 'rust:1-alpine');

  const ExecutionLanguage(this.interpreter, this.extensions, this.dockerImage);

  final String interpreter;
  final List<String> extensions;

  /// Official docker image per language (network always `--network=none`).
  final String dockerImage;

  bool get needsCompile => switch (this) {
        ExecutionLanguage.c ||
        ExecutionLanguage.cpp ||
        ExecutionLanguage.rust => true,
        _ => false,
      };

  /// Full argv to run a single source file (interpreted languages), executed
  /// with the file's directory or [workingDirectory] as cwd.
  List<String> runArgv(String scriptPath) => switch (this) {
        ExecutionLanguage.python => [interpreter, scriptPath],
        ExecutionLanguage.javascript => [interpreter, scriptPath],
        ExecutionLanguage.bash => [interpreter, scriptPath],
        ExecutionLanguage.dart ||
        ExecutionLanguage.go => [interpreter, 'run', scriptPath],
        ExecutionLanguage.java => [interpreter, scriptPath],
        _ => throw UnsupportedError('$name butuh tahap compile'),
      };

  /// One-step compile+run shell command (compiled languages), run with cwd
  /// set to the source file's directory. Binary name is fixed and lives in
  /// the temp dir so repeated runs cannot clash with user files.
  String compileAndRun(String scriptName) => switch (this) {
        ExecutionLanguage.c =>
          'gcc -O1 "$scriptName" -o tiko_prog && ./tiko_prog',
        ExecutionLanguage.cpp =>
          'g++ -O1 "$scriptName" -o tiko_prog && ./tiko_prog',
        ExecutionLanguage.rust =>
          'rustc -O "$scriptName" -o tiko_prog && ./tiko_prog',
        _ => throw UnsupportedError('$name tidak butuh compile'),
      };

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
    this.allowedLanguages = ExecutionLanguage.values,
    this.sandboxKind = SandboxKind.none,
    this.dockerImage = 'python:3.13-alpine',
    this.tempDirectory,
    this.workingDirectory,
    this.allowFileWrite = false,
    this.allowNetworkAccess = false,
    this.maxMemoryMb = 512,
    this.allowUnsafeLocalExecution = false,
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

  /// Fail-closed escape hatch: when no OS sandbox is available, code
  /// execution is refused unless the operator explicitly opts in to running
  /// code directly on the host via [LocalCodeExecutionProvider].
  final bool allowUnsafeLocalExecution;

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
    bool? allowUnsafeLocalExecution,
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
      allowUnsafeLocalExecution:
          allowUnsafeLocalExecution ?? this.allowUnsafeLocalExecution,
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

  /// Cheap availability probe for the language's interpreter/compiler on the
  /// host. Used by tests and tooling (doctor) to degrade gracefully instead
  /// of surfacing raw `ProcessException` to the model.
  static Future<bool> interpreterAvailable(ExecutionLanguage language) async {
    final probe = switch (language) {
      ExecutionLanguage.go => const ['version'],
      ExecutionLanguage.java => const ['-version'],
      _ => const ['--version'],
    };
    try {
      final r = await Process.run(language.interpreter, probe);
      return r.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

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
        var timedOut = false;
        final ProcessResult result;
        if (language.needsCompile) {
          // Compile-then-run in one step, cwd = temp dir so the binary
          // never lands in the workspace.
          result = await Process.run(
            'sh',
            ['-c', language.compileAndRun(p.basename(tempFile.path))],
            workingDirectory: tempDir.path,
            environment: env,
          ).timeout(
            timeout ?? Duration(seconds: config.timeoutSeconds),
            onTimeout: () {
              timedOut = true;
              return ProcessResult(-1, -1, '', '');
            },
          );
        } else {
          final args = language.runArgv(tempFile.path);
          result = await Process.run(
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
        }

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
        } catch (_) {} // best-effort
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
        } catch (_) {} // best-effort
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
        final List<String> dockerArgs = [
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

        final String command;
        // Entry image: config.dockerImage overrides only the python default;
        // other languages pin their official image (F8.3).
        final image = language == ExecutionLanguage.python
            ? dockerImage
            : language.dockerImage;
        final mounted = '/tmp/tiko_code${language.extensions.first}';
        command = switch (language) {
          ExecutionLanguage.python => 'python $mounted',
          ExecutionLanguage.javascript => 'node $mounted',
          ExecutionLanguage.bash => 'bash $mounted',
          ExecutionLanguage.dart => 'dart run $mounted',
          ExecutionLanguage.java => 'java $mounted',
          ExecutionLanguage.go => 'go run $mounted',
          _ => language.compileAndRun(p.basename(mounted)),
        };
        dockerArgs.add(image);
        dockerArgs.addAll(['sh', '-c', command]);

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
        } catch (_) {} // best-effort
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
    if (config.allowUnsafeLocalExecution) {
      return LocalCodeExecutionProvider();
    }
    return _DisabledCodeExecutionProvider();
  }

  String get name => 'code_execution';

  String get description =>
      'Execute code in a sandboxed environment. Supports Python, JavaScript, '
      'Bash, Dart, Java, Go, C, C++, and Rust (compiled languages are first '
      'compiled from a single file, then run). Code is executed with timeout '
      'and resource limits; unsupported languages on the active provider '
      'fail-soft with an explicit error.';

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

      final effectiveProvider = _effectiveProvider;
      if (effectiveProvider is _DisabledCodeExecutionProvider) {
        return ToolResult(
          callId: '',
          content: jsonEncode({
            'success': false,
            'error': effectiveProvider.disabledReason,
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

/// Fail-closed provider: refuses to execute when no OS sandbox backend is
/// available. Prevents silent fallback to unsandboxed host execution.
class _DisabledCodeExecutionProvider implements CodeExecutionProvider {
  String get disabledReason =>
      'Eksekusi kode dinonaktifkan: OS sandbox tidak tersedia (fail-closed). '
      'Sediakan SandboxRunner dengan backend bwrap/docker, atau set '
      'allowUnsafeLocalExecution=true untuk eksekusi host secara eksplisit.';

  @override
  String get name => 'disabled';

  @override
  List<ExecutionLanguage> get supportedLanguages => const [];

  @override
  Future<bool> isAvailable() async => false;

  @override
  Future<CodeExecutionResult> execute({
    required String code,
    required ExecutionLanguage language,
    required CodeExecutionConfig config,
    String? workingDirectory,
    Map<String, String>? environment,
    Duration? timeout,
  }) async {
    return CodeExecutionResult(
      success: false,
      error: disabledReason,
      exitCode: -1,
    );
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

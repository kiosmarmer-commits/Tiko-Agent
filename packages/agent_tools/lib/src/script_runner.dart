import 'dart:convert';
import 'dart:io';

import 'package:agent_core/agent_core.dart';
import 'package:path/path.dart' as p;

import 'sandbox.dart';

/// Loads script tools from tools/<name>/tool.json and runs them only when a
/// working OS sandbox is available. No host-process fallback is permitted.
///
/// Each tool receives a private temporary copy of its own files as the sandbox
/// workspace. It cannot read/write the complete project or another tool's
/// directory. `.env`, VCS metadata, caches, symlinks and special files are
/// never copied.
class ScriptToolRunner {
  ScriptToolRunner({
    required this.toolsDir,
    SandboxRunner? sandbox,
    this.defaultTimeoutSec = 30,
  }) : sandbox = sandbox ?? SandboxRunner(workspacePath: toolsDir);

  final String toolsDir;
  final SandboxRunner sandbox;
  final int defaultTimeoutSec;
  Directory? _privateRoot;
  bool _closed = false;

  /// Discover and load valid script tools. With no OS sandbox the result is
  /// intentionally empty rather than silently enabling host execution.
  Future<List<ScriptTool>> loadAll() async {
    if (_closed) throw StateError('script runner is closed');
    if (sandbox.kind == SandboxKind.none) return const [];
    final dir = Directory(toolsDir);
    if (!await dir.exists()) return const [];
    final sandboxRootDir = Directory(sandbox.workspacePath).absolute;
    await sandboxRootDir.create(recursive: true);
    final sandboxRoot = await sandboxRootDir.resolveSymbolicLinks();
    final root = await dir.resolveSymbolicLinks();
    if (!_isWithin(sandboxRoot, root)) return const [];
    final canonicalToolsDir = Directory(root);

    final privateRoot = _privateRoot ??= await Directory.systemTemp.createTemp('tiko-script-tools-');
    final tools = <ScriptTool>[];
    var index = 0;
    await for (final entity in canonicalToolsDir.list(followLinks: false)) {
      if (entity is! Directory) continue;
      index++;
      Directory? privateDir;
      try {
        final realDir = await entity.resolveSymbolicLinks();
        if (!_isWithin(root, realDir)) continue;
        final toolJson = File(p.join(realDir, 'tool.json'));
        if (FileSystemEntity.typeSync(toolJson.path, followLinks: false) != FileSystemEntityType.file) continue;
        final realToolJson = await toolJson.resolveSymbolicLinks();
        if (!_isWithin(root, realToolJson)) continue;
        final info = await toolJson.stat();
        if (info.type != FileSystemEntityType.file || info.size > 64 * 1024) continue;
        final decoded = jsonDecode(await toolJson.readAsString());
        if (decoded is! Map<String, dynamic>) continue;
        final name = decoded['name'];
        if (name is! String || !RegExp(r'^[a-z][a-z0-9_]{0,63}$').hasMatch(name)) continue;

        privateDir = Directory(p.join(privateRoot.path, 'tool_$index'));
        await _copyPrivateTool(realDir, privateDir);
        final isolatedSandbox = SandboxRunner(
          kind: sandbox.kind,
          dockerImage: sandbox.dockerImage,
          workspacePath: privateDir.path,
          maxOutputBytes: sandbox.maxOutputBytes,
        );
        tools.add(ScriptTool.fromJson(
          decoded,
          privateDir.path,
          sandbox: isolatedSandbox,
          defaultTimeoutSec: defaultTimeoutSec,
        ));
      } catch (_) {
        // Invalid/unsafe definitions remain disabled; never load partially.
        if (privateDir != null) {
          try {
            if (await privateDir.exists()) await privateDir.delete(recursive: true);
          } catch (_) {}
        }
      }
    }
    return List.unmodifiable(tools);
  }

  Future<void> _copyPrivateTool(String sourcePath, Directory destination) async {
    final source = Directory(sourcePath);
    final sourceRoot = await source.resolveSymbolicLinks();
    await destination.create(recursive: true);
    final destRoot = await destination.resolveSymbolicLinks();
    final base = _privateRoot;
    if (base == null) throw StateError('private script root was not initialized');
    final privateBase = await base.resolveSymbolicLinks();
    if (!_isWithin(privateBase, destRoot)) {
      throw StateError('private script directory escaped temporary root');
    }

    var totalBytes = 0;
    var fileCount = 0;
    const maxFiles = 200;
    const maxTotalBytes = 5 * 1024 * 1024;
    const excludedSegments = {
      '.git', '.tiko', 'node_modules', '__pycache__', '.dart_tool',
      'build', '.venv', 'venv',
    };

    await for (final entity in source.list(recursive: true, followLinks: false)) {
      final relative = p.relative(entity.path, from: sourceRoot);
      if (relative == '.' || p.isAbsolute(relative) || relative.split(p.separator).any((s) => s == '..')) {
        throw StateError('unsafe relative path in script tool');
      }
      final segments = p.split(relative);
      if (segments.any(excludedSegments.contains)) continue;
      if (segments.any((s) => s == '.env' || s.startsWith('.env.')) ||
          segments.last == 'tool.json' || segments.last == '.DS_Store') {
        continue;
      }

      final type = await FileSystemEntity.type(entity.path, followLinks: false);
      if (type == FileSystemEntityType.link) {
        throw StateError('script tool contains symlink: $relative');
      }
      final targetPath = p.join(destRoot, relative);
      if (type == FileSystemEntityType.directory) {
        await Directory(targetPath).create(recursive: true);
        continue;
      }
      if (type != FileSystemEntityType.file) {
        throw StateError('script tool contains unsupported file type: $relative');
      }
      fileCount++;
      if (fileCount > maxFiles) throw StateError('script tool exceeds $maxFiles files');
      final file = File(entity.path);
      final length = await file.length();
      if (length > 1024 * 1024 || totalBytes + length > maxTotalBytes) {
        throw StateError('script tool files exceed size limit');
      }
      totalBytes += length;
      final target = File(targetPath);
      await target.parent.create(recursive: true);
      await file.copy(target.path);
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final root = _privateRoot;
    _privateRoot = null;
    if (root == null) return;
    try {
      if (await FileSystemEntity.type(root.path, followLinks: false) == FileSystemEntityType.directory) {
        final resolved = await root.resolveSymbolicLinks();
        final temp = await Directory.systemTemp.resolveSymbolicLinks();
        if (_isWithin(temp, resolved)) await Directory(resolved).delete(recursive: true);
      }
    } catch (_) {
      // Cleanup is best-effort and must not interrupt runtime shutdown.
    }
  }

  bool _isWithin(String root, String path) =>
      path == root || path.startsWith(p.normalize(root + p.separator));
}

class ScriptTool implements Tool {
  ScriptTool({
    required this.spec,
    required this.command,
    required this.workingDirectory,
    required this.sandbox,
  });

  @override
  final ToolSpec spec;
  final List<String> command;
  final String workingDirectory;
  final SandboxRunner sandbox;

  factory ScriptTool.fromJson(
    Map<String, dynamic> json,
    String dir, {
    required SandboxRunner sandbox,
    int defaultTimeoutSec = 30,
  }) {
    final runtime = json['runtime'];
    if (runtime != null && runtime is! Map<String, dynamic>) {
      throw const FormatException('runtime must be an object');
    }
    final runtimeMap = runtime as Map<String, dynamic>? ?? const {};
    final rawCommand = runtimeMap['command'];
    final command = rawCommand == null
        ? <String>['python3', 'run.py']
        : rawCommand is List
            ? rawCommand.map((item) {
                if (item is! String || item.trim().isEmpty || item.contains('\u0000')) {
                  throw const FormatException('runtime.command contains invalid argument');
                }
                return item;
              }).toList()
            : throw const FormatException('runtime.command must be a string array');
    if (command.isEmpty || command.length > 32) {
      throw const FormatException('runtime.command must contain 1..32 arguments');
    }
    if (command.fold<int>(0, (sum, part) => sum + part.length) > 8192 ||
        command.any((part) => part.length > 2048)) {
      throw const FormatException('runtime.command exceeds argument limits');
    }

    final rawName = json['name'];
    if (rawName is! String || !RegExp(r'^[a-z][a-z0-9_]{0,63}$').hasMatch(rawName)) {
      throw const FormatException('invalid tool name');
    }
    final rawSchema = json['input_schema'];
    if (rawSchema != null && rawSchema is! Map<String, dynamic>) {
      throw const FormatException('input_schema must be an object');
    }
    final rawRisk = json['risk'];
    final risk = rawRisk == null ? 'high' : rawRisk;
    if (risk is! String || !const {'low', 'medium', 'high', 'critical'}.contains(risk)) {
      throw const FormatException('invalid tool risk');
    }
    if (defaultTimeoutSec < 1 || defaultTimeoutSec > 60) {
      throw ArgumentError.value(defaultTimeoutSec, 'defaultTimeoutSec', 'must be 1..60');
    }
    final timeout = _boundedInt(json['timeout_sec'], fallback: defaultTimeoutSec, min: 1, max: 60);
    final maxOutput = _boundedInt(json['max_output_chars'], fallback: 20000, min: 1, max: 50000);
    final description = json['description'];
    if (description != null && description is! String) {
      throw const FormatException('description must be a string');
    }

    return ScriptTool(
      spec: ToolSpec(
        name: 'script_$rawName',
        description: description as String? ?? '',
        inputSchema: rawSchema as Map<String, dynamic>? ?? const {
          'type': 'object',
          'properties': <String, dynamic>{},
        },
        risk: risk,
        timeoutSec: timeout,
        maxOutputChars: maxOutput,
      ),
      command: List.unmodifiable(command),
      workingDirectory: dir,
      sandbox: sandbox,
    );
  }

  static int _boundedInt(
    Object? value, {
    required int fallback,
    required int min,
    required int max,
  }) {
    if (value == null) return fallback;
    if (value is! int || value < min || value > max) {
      throw FormatException('value must be an integer between $min and $max');
    }
    return value;
  }

  @override
  Future<ToolResult> run(Map<String, dynamic> args, ToolContext ctx) async {
    if (sandbox.kind == SandboxKind.none) {
      return const ToolResult(
        callId: '',
        content: 'Script dinonaktifkan: OS sandbox tidak tersedia.',
        isError: true,
      );
    }
    final payload = jsonEncode(args);
    if (utf8.encode(payload).length > 64 * 1024) {
      return const ToolResult(callId: '', content: 'input terlalu besar', isError: true);
    }
    try {
      final result = await sandbox.run(
        command,
        workingDirectory: workingDirectory,
        stdinText: payload,
        timeout: Duration(seconds: spec.timeoutSec),
      );
      final stdoutText = (result.stdout as String);
      final stderrText = (result.stderr as String);
      if (result.exitCode != 0) {
        return ToolResult(
          callId: '',
          content: 'exit ${result.exitCode}\nstderr: ${_limit(stderrText, spec.maxOutputChars)}',
          isError: true,
        );
      }
      try {
        final decoded = jsonDecode(stdoutText);
        if (decoded is Map && decoded.containsKey('content')) {
          return ToolResult(
            callId: '',
            content: _limit(decoded['content'].toString(), spec.maxOutputChars),
            isError: decoded['is_error'] == true,
          );
        }
      } catch (_) {
        // Raw stdout is a supported legacy response format.
      }
      return ToolResult(callId: '', content: _limit(stdoutText, spec.maxOutputChars));
    } on TimeoutException {
      return const ToolResult(callId: '', content: 'timeout', isError: true);
    } catch (error) {
      return ToolResult(callId: '', content: 'script error: $error', isError: true);
    }
  }

  String _limit(String value, int max) => value.length <= max
      ? value
      : '${value.substring(0, max)}\n…[truncated]';
}

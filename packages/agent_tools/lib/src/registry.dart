import 'package:agent_core/agent_core.dart';

/// Central tool registry with JSON Schema argument validation (TASK-03-01).
class ToolRegistry {
  final Map<String, Tool> _tools = {};

  void register(Tool tool) => registerAll([tool]);

  /// Preflights the complete batch before mutating the registry. This is
  /// important for MCP/plugin loading: a late collision must not leave a
  /// partially registered server whose client has already been closed.
  void registerAll(Iterable<Tool> tools) {
    final pending = <String, Tool>{};
    for (final tool in tools) {
      final name = tool.spec.name.trim();
      if (name.isEmpty || name != tool.spec.name) {
        throw ArgumentError.value(
          tool.spec.name,
          'tool.spec.name',
          'must be non-empty and trimmed',
        );
      }
      if (_tools.containsKey(name) || pending.containsKey(name)) {
        throw StateError('Tool already registered: $name');
      }
      pending[name] = tool;
    }
    _tools.addAll(pending);
  }

  Tool? get(String name) => _tools[name];

  List<ToolSpec> get specs => _tools.values.map((t) => t.spec).toList();

  List<String> get names => _tools.keys.toList();

  /// Validates [args] against the tool's input_schema (subset of JSON Schema).
  /// Returns null if valid, or an error message.
  String? validateArgs(String toolName, Map<String, dynamic> args) {
    final tool = _tools[toolName];
    if (tool == null) return 'Unknown tool: $toolName';
    final schema = tool.spec.inputSchema;
    return _validateObject(schema, args, path: '');
  }

  String? _validateObject(
    Map<String, dynamic> schema,
    Map<String, dynamic> data, {
    required String path,
  }) {
    final type = schema['type'];
    if (type != null && type != 'object') {
      return 'Expected object at $path';
    }
    final rawProps = schema['properties'];
    final props = rawProps is Map
        ? Map<String, dynamic>.from(rawProps)
        : const <String, dynamic>{};
    final required =
        (schema['required'] as List<dynamic>?)?.cast<String>() ?? [];

    for (final r in required) {
      if (!data.containsKey(r)) {
        return 'Missing required field: ${path.isEmpty ? r : '$path.$r'}';
      }
    }

    for (final entry in data.entries) {
      final key = entry.key;
      final val = entry.value;
      final rawPropSchema = props[key];
      final propSchema = rawPropSchema is Map
          ? Map<String, dynamic>.from(rawPropSchema)
          : null;
      if (propSchema == null) {
        // additionalProperties default true for flexibility
        continue;
      }
      final err = _validateValue(
        propSchema,
        val,
        path: path.isEmpty ? key : '$path.$key',
      );
      if (err != null) return err;
    }
    return null;
  }

  String? _validateValue(
    Map<String, dynamic> schema,
    dynamic value, {
    required String path,
  }) {
    final type = schema['type'] as String?;
    if (type == null) return null;
    switch (type) {
      case 'string':
        if (value is! String) return 'Expected string at $path';
        final minLen = schema['minLength'] as int?;
        if (minLen != null && value.length < minLen) {
          return 'String too short at $path';
        }
        break;
      case 'number':
      case 'integer':
        if (value is! num) return 'Expected number at $path';
        if (type == 'integer' &&
            value is! int &&
            value != value.roundToDouble()) {
          return 'Expected integer at $path';
        }
        break;
      case 'boolean':
        if (value is! bool) return 'Expected boolean at $path';
        break;
      case 'array':
        if (value is! List) return 'Expected array at $path';
        break;
      case 'object':
        if (value is! Map) return 'Expected object at $path';
        return _validateObject(
          schema,
          Map<String, dynamic>.from(value),
          path: path,
        );
    }
    final enumVals = schema['enum'] as List<dynamic>?;
    if (enumVals != null && !enumVals.contains(value)) {
      return 'Value not in enum at $path';
    }
    return null;
  }
}

/// Default executor that looks up tools in a [ToolRegistry].
class RegistryToolExecutor implements ToolExecutor {
  RegistryToolExecutor(this.registry);

  final ToolRegistry registry;

  @override
  Future<ToolResult> run(ToolCall call, ToolContext ctx) async {
    final tool = registry.get(call.name);
    if (tool == null) {
      return ToolResult(
        callId: call.id,
        content: 'Unknown tool: ${call.name}',
        isError: true,
      );
    }

    final validationError = registry.validateArgs(call.name, call.args);
    if (validationError != null) {
      return ToolResult(
        callId: call.id,
        content: 'Invalid arguments: $validationError',
        isError: true,
      );
    }

    final sw = Stopwatch()..start();
    try {
      final result = await tool
          .run(call.args, ctx)
          .timeout(Duration(seconds: tool.spec.timeoutSec));
      sw.stop();
      var content = result.content;
      if (content.length > tool.spec.maxOutputChars) {
        content =
            '${content.substring(0, tool.spec.maxOutputChars)}\n…[truncated]';
      }
      return ToolResult(
        callId: call.id,
        content: content,
        isError: result.isError,
        durationMs: sw.elapsedMilliseconds,
      );
    } catch (e) {
      sw.stop();
      return ToolResult(
        callId: call.id,
        content: 'Tool error: $e',
        isError: true,
        durationMs: sw.elapsedMilliseconds,
      );
    }
  }
}

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

  /// Snapshot tool berdaftar saat ini (dipakai integrasi IDE/ACP agar
  /// tool yang dimuat belakangan — MCP/script — tetap terlihat).
  List<Tool> get all => List.unmodifiable(_tools.values);

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

    // P1-4: Check additionalProperties
    final additionalProperties = schema['additionalProperties'];
    if (additionalProperties == false) {
      // No additional properties allowed
      for (final key in data.keys) {
        if (!props.containsKey(key)) {
          return 'Additional property not allowed: ${path.isEmpty ? key : '$path.$key'}';
        }
      }
    }

    // P1-4: Check maxProperties and minProperties
    final maxProperties = schema['maxProperties'] as int?;
    if (maxProperties != null && data.length > maxProperties) {
      return 'Too many properties at $path (max: $maxProperties)';
    }
    final minProperties = schema['minProperties'] as int?;
    if (minProperties != null && data.length < minProperties) {
      return 'Too few properties at $path (min: $minProperties)';
    }

    for (final entry in data.entries) {
      final key = entry.key;
      final val = entry.value;
      final rawPropSchema = props[key];
      final propSchema = rawPropSchema is Map
          ? Map<String, dynamic>.from(rawPropSchema)
          : null;
      if (propSchema == null) {
        // If additionalProperties is not explicitly false, allow it
        if (additionalProperties == false) {
          return 'Additional property not allowed: ${path.isEmpty ? key : '$path.$key'}';
        }
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
    
    // P1-4: Handle enum validation first (applies to all types)
    final enumVals = schema['enum'] as List<dynamic>?;
    if (enumVals != null && !enumVals.contains(value)) {
      return 'Value not in enum at $path';
    }
    
    switch (type) {
      case 'string':
        if (value is! String) return 'Expected string at $path';
        final minLen = schema['minLength'] as int?;
        if (minLen != null && value.length < minLen) {
          return 'String too short at $path (min: $minLen)';
        }
        final maxLen = schema['maxLength'] as int?;
        if (maxLen != null && value.length > maxLen) {
          return 'String too long at $path (max: $maxLen)';
        }
        // P1-4: Pattern validation
        final pattern = schema['pattern'] as String?;
        if (pattern != null) {
          final regex = RegExp(pattern);
          if (!regex.hasMatch(value)) {
            return 'String does not match pattern at $path';
          }
        }
        // P1-4: Format validation (simplified)
        final format = schema['format'] as String?;
        if (format != null) {
          final formatError = _validateFormat(value, format, path);
          if (formatError != null) return formatError;
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
        // P1-4: Number range validation
        final minimum = schema['minimum'] as num?;
        if (minimum != null && value < minimum) {
          final exclusive = schema['exclusiveMinimum'] as bool? ?? false;
          if (exclusive && value <= minimum || !exclusive && value < minimum) {
            return 'Value below minimum at $path (min: $minimum, exclusive: $exclusive)';
          }
        }
        final maximum = schema['maximum'] as num?;
        if (maximum != null && value > maximum) {
          final exclusive = schema['exclusiveMaximum'] as bool? ?? false;
          if (exclusive && value >= maximum || !exclusive && value > maximum) {
            return 'Value above maximum at $path (max: $maximum, exclusive: $exclusive)';
          }
        }
        // P1-4: MultipleOf validation
        final multipleOf = schema['multipleOf'] as num?;
        if (multipleOf != null) {
          final remainder = value % multipleOf;
          if (remainder != 0) {
            return 'Value must be a multiple of $multipleOf at $path';
          }
        }
        break;
      case 'boolean':
        if (value is! bool) return 'Expected boolean at $path';
        break;
      case 'array':
        if (value is! List) return 'Expected array at $path';
        // P1-4: Array validation
        final minItems = schema['minItems'] as int?;
        if (minItems != null && value.length < minItems) {
          return 'Array too short at $path (min: $minItems)';
        }
        final maxItems = schema['maxItems'] as int?;
        if (maxItems != null && value.length > maxItems) {
          return 'Array too long at $path (max: $maxItems)';
        }
        // P1-4: Validate items schema
        final itemsSchema = schema['items'];
        if (itemsSchema != null) {
          for (var i = 0; i < value.length; i++) {
            final item = value[i];
            if (itemsSchema is Map) {
              final err = _validateValue(
                Map<String, dynamic>.from(itemsSchema),
                item,
                path: '$path[$i]',
              );
              if (err != null) return err;
            } else if (itemsSchema is List) {
              // Tuple validation - each position can have different schema
              final schemas = itemsSchema.cast<Map<String, dynamic>>();
              if (i < schemas.length) {
                final err = _validateValue(
                  schemas[i],
                  item,
                  path: '$path[$i]',
                );
                if (err != null) return err;
              }
            }
          }
        }
        // P1-4: Unique items validation
        final uniqueItems = schema['uniqueItems'] as bool?;
        if (uniqueItems == true) {
          final seen = <dynamic>{};
          for (final item in value) {
            if (seen.contains(item)) {
              return 'Array contains duplicate items at $path';
            }
            seen.add(item);
          }
        }
        break;
      case 'object':
        if (value is! Map) return 'Expected object at $path';
        return _validateObject(
          schema,
          Map<String, dynamic>.from(value),
          path: path,
        );
    }
    return null;
  }

  /// P1-4: Format validation helper
  String? _validateFormat(String value, String format, String path) {
    switch (format) {
      case 'uri':
        try {
          Uri.parse(value);
          return null;
        } catch (_) {
          return 'Invalid URI format at $path';
        }
      case 'email':
        // Simple email validation
        if (!RegExp(r'^[^@]+@[^@]+\.[^@]+$').hasMatch(value)) {
          return 'Invalid email format at $path';
        }
        return null;
      case 'uuid':
        // UUID v4 validation
        if (!RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$', caseSensitive: false).hasMatch(value)) {
          return 'Invalid UUID format at $path';
        }
        return null;
      case 'date-time':
        try {
          DateTime.parse(value);
          return null;
        } catch (_) {
          return 'Invalid date-time format at $path';
        }
      case 'date':
        try {
          // Try to parse as date only
          if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value)) {
            return 'Invalid date format at $path (expected YYYY-MM-DD)';
          }
          DateTime.parse(value);
          return null;
        } catch (_) {
          return 'Invalid date format at $path';
        }
      case 'ipv4':
        // Simple IPv4 validation
        final parts = value.split('.');
        if (parts.length != 4) return 'Invalid IPv4 format at $path';
        for (final part in parts) {
          final numPart = int.tryParse(part);
          if (numPart == null || numPart < 0 || numPart > 255) {
            return 'Invalid IPv4 format at $path';
          }
        }
        return null;
      default:
        // Unknown format - skip validation
        return null;
    }
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
    final timeoutDur = Duration(seconds: tool.spec.timeoutSec);
    final graceDur = Duration(seconds: 2); // Grace period for cleanup
    
    // P1-3: Use cooperative cancellation instead of just timing out.
    // Create a new token specifically for this tool call that can be cancelled.
    final toolCancel = CancellationToken();
    final ctxWithCancel = ToolContext(
      session: ctx.session,
      workspacePath: ctx.workspacePath,
      tainted: ctx.tainted,
      cancelToken: toolCancel,
    );
    
    final toolFuture = tool.run(call.args, ctxWithCancel);
    
    try {
      final result = await toolFuture.timeout(timeoutDur);
      sw.stop();
      var content = result.content;
      if (content.length > tool.spec.maxOutputChars) {
        content =
            '${content.substring(0, tool.spec.maxOutputChars)}\n\u2026[truncated]';
      }
      return ToolResult(
        callId: call.id,
        content: content,
        isError: result.isError,
        durationMs: sw.elapsedMilliseconds,
      );
    } catch (e) {
      sw.stop();
      // Cancel the tool's cancellation token to signal it should stop
      toolCancel.cancel();
      
      // Wait briefly for the tool to notice the cancellation and clean up
      // This prevents orphaned processes/operations
      try {
        await toolFuture.timeout(graceDur);
      } catch (_) {
        // Tool didn't complete within grace period - it may still be running
        // but we've signalled cancellation
      }
      
      return ToolResult(
        callId: call.id,
        content: 'Tool timeout after ${tool.spec.timeoutSec}s: ${e.toString().length > 200 ? e.toString().substring(0, 200) : e.toString()}',
        isError: true,
        durationMs: sw.elapsedMilliseconds,
      );
    }
  }
}

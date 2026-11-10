/// Plugin system (Hermes-style): general plugins (tool hooks), memory
/// providers (cross-session knowledge backends), and context engines
/// (alternative context assembly).
///
/// Design rules:
/// - Plugins are isolated: a throwing plugin never breaks the agent loop;
///   the host records the error via [PluginEvent.error].
/// - Hooks run in registration order; the first explicit denial wins.
/// - Everything is in-memory and dependency-free; persistence and network
///   adapters live in concrete implementations (see `agent_memory`'s
///   `HttpMemoryProvider`).

/// Lifecycle points where a plugin can observe or veto agent activity.
enum PluginHook {
  beforeToolCall,
  afterToolCall,
  onSessionStart,
  onSessionEnd,
  onMessage,
}

/// Input passed to a `beforeToolCall` hook.
class ToolHookInput {
  const ToolHookInput({
    required this.toolName,
    required this.args,
    required this.sessionId,
  });

  final String toolName;
  final Map<String, dynamic> args;
  final String sessionId;
}

/// Verdict of a `beforeToolCall` hook chain.
class HookVerdict {
  const HookVerdict.allow({this.reason})
      : allowed = true,
        modifiedArgs = null;

  const HookVerdict.deny({required this.reason})
      : allowed = false,
        modifiedArgs = null;

  const HookVerdict.modify(Map<String, dynamic> this.modifiedArgs)
      : allowed = true,
        reason = null;

  final bool allowed;
  final String? reason;

  /// Replacement args when produced by [HookVerdict.modify]; null keeps
  /// the original args.
  final Map<String, dynamic>? modifiedArgs;
}

/// Error or lifecycle observation emitted by the host about a plugin.
class PluginEvent {
  PluginEvent({
    required this.pluginName,
    required this.hook,
    this.error,
    this.detail,
  }) : at = DateTime.now().toUtc();

  final String pluginName;
  final PluginHook hook;
  final Object? error;
  final String? detail;
  final DateTime at;
}

/// Base class for agent plugins. Override only the hooks you need; the
/// defaults are passive.
abstract class Plugin {
  String get name;
  String get version => '0.1.0';

  Future<void> init() async {}
  Future<void> dispose() async {}

  /// Return [HookVerdict.deny] to veto a tool call, [HookVerdict.modify]
  /// to rewrite args, or the default allow.
  Future<HookVerdict> beforeToolCall(ToolHookInput input) =>
      Future.value(const HookVerdict.allow());

  Future<void> afterToolCall(
    ToolHookInput input,
    String result,
    bool isError,
  ) async {}

  Future<void> onSessionStart(String sessionId) async {}
  Future<void> onSessionEnd(String sessionId) async {}
  Future<void> onMessage(String sessionId, String text,
      {required bool fromUser}) async {}
}

/// One external memory record exchanged with a [MemoryProvider].
class MemoryRecord {
  const MemoryRecord({
    required this.id,
    required this.text,
    this.score = 0.0,
    this.ownerKey,
    this.tags = const [],
    this.createdAt,
  });

  final String id;
  final String text;
  final double score;
  final String? ownerKey;
  final List<String> tags;
  final DateTime? createdAt;

  Map<String, dynamic> toJson() => {
        'id': id,
        'text': text,
        'score': score,
        if (ownerKey != null) 'owner_key': ownerKey,
        'tags': tags,
        if (createdAt != null) 'created_at': createdAt!.toIso8601String(),
      };

  factory MemoryRecord.fromJson(Map<String, dynamic> json) => MemoryRecord(
        id: json['id'] as String? ?? '',
        text: json['text'] as String? ?? '',
        score: (json['score'] as num?)?.toDouble() ?? 0.0,
        ownerKey: json['owner_key'] as String?,
        tags: (json['tags'] as List<dynamic>?)?.map((e) => e.toString())
            .toList() ?? const [],
        createdAt: DateTime.tryParse(json['created_at'] as String? ?? ''),
      );
}

/// Contract for external memory backends (RetainDB, ByteRover, Mem0-style
/// services, or any HTTP/daemon store). Implementations must be safe to
/// call concurrently; hosts should treat failures as degraded retrieval,
/// never as fatal.
abstract class MemoryProvider {
  String get name;

  Future<void> upsert(MemoryRecord record);
  Future<List<MemoryRecord>> search(String query,
      {int k = 8, String? ownerKey});
  Future<void> forget(String id);
}

/// Contract for pluggable context engines (alternative context assembly
/// strategies replacing the default ContextBuilder output when installed).
abstract class ContextEngine {
  String get name;

  /// Builds the context block for [query] within [maxChars].
  Future<String> buildContext(String query, {int maxChars = 4000});
}

/// Registry and dispatch host for plugins.
class PluginRegistry {
  final List<Plugin> _plugins = [];
  final List<PluginEvent> events = [];

  List<Plugin> get plugins => List<Plugin>.unmodifiable(_plugins);

  int get length => _plugins.length;

  bool has(String name) => _plugins.any((p) => p.name == name);

  Plugin? get(String name) {
    for (final p in _plugins) {
      if (p.name == name) return p;
    }
    return null;
  }

  /// Initializes and registers [plugin]. Re-registering the same name
  /// replaces the previous instance (dispose is called on the old one).
  Future<void> register(Plugin plugin) async {
    final existing = get(plugin.name);
    if (existing != null) {
      await _safe(() => existing.dispose(), existing.name,
          PluginHook.onSessionEnd);
      _plugins.remove(existing);
    }
    await _safe(plugin.init, plugin.name, PluginHook.onSessionStart,
        detail: 'init');
    _plugins.add(plugin);
  }

  Future<void> unregister(String name) async {
    final plugin = get(name);
    if (plugin == null) return;
    _plugins.remove(plugin);
    await _safe(() => plugin.dispose(), name, PluginHook.onSessionEnd,
        detail: 'dispose');
  }

  /// Runs the beforeToolCall chain in registration order. First denial
  /// wins; arg modifications chain into the next hook's input.
  Future<HookVerdict> dispatchBeforeToolCall(ToolHookInput input) async {
    var args = input.args;
    for (final plugin in _plugins) {
      HookVerdict verdict = const HookVerdict.allow();
      final ok = await _safe(
        () async => verdict = await plugin.beforeToolCall(
          ToolHookInput(
            toolName: input.toolName,
            args: args,
            sessionId: input.sessionId,
          ),
        ),
        plugin.name,
        PluginHook.beforeToolCall,
      );
      if (!ok) continue;
      if (!verdict.allowed) return verdict;
      if (verdict.modifiedArgs != null) args = verdict.modifiedArgs!;
    }
    return args == input.args
        ? const HookVerdict.allow()
        : HookVerdict.modify(args);
  }

  Future<void> dispatchAfterToolCall(
    ToolHookInput input,
    String result,
    bool isError,
  ) async {
    for (final plugin in _plugins) {
      await _safe(
        () => plugin.afterToolCall(input, result, isError),
        plugin.name,
        PluginHook.afterToolCall,
      );
    }
  }

  Future<void> dispatchSessionStart(String sessionId) async {
    for (final plugin in _plugins) {
      await _safe(() => plugin.onSessionStart(sessionId), plugin.name,
          PluginHook.onSessionStart);
    }
  }

  Future<void> dispatchSessionEnd(String sessionId) async {
    for (final plugin in _plugins) {
      await _safe(() => plugin.onSessionEnd(sessionId), plugin.name,
          PluginHook.onSessionEnd);
    }
  }

  Future<void> dispatchMessage(
    String sessionId,
    String text, {
    required bool fromUser,
  }) async {
    for (final plugin in _plugins) {
      await _safe(
        () => plugin.onMessage(sessionId, text, fromUser: fromUser),
        plugin.name,
        PluginHook.onMessage,
      );
    }
  }

  Future<void> disposeAll() async {
    for (final plugin in List<Plugin>.from(_plugins)) {
      await _safe(() => plugin.dispose(), plugin.name,
          PluginHook.onSessionEnd, detail: 'dispose');
    }
    _plugins.clear();
  }

  Future<bool> _safe(
    Future<void> Function() fn,
    String pluginName,
    PluginHook hook, {
    String? detail,
  }) async {
    try {
      await fn();
      return true;
    } catch (e) {
      events.add(PluginEvent(pluginName: pluginName, hook: hook, error: e,
          detail: detail));
      return false;
    }
  }
}

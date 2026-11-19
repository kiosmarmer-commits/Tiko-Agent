/// Bot Mode: durable, addressable specialists inside a group conversation.
///
/// Layers on top of [AgentRegistry] instead of duplicating it: a bot is an
/// existing [AgentSpec] plus a stable chat handle and an enabled flag, so
/// persona, tool allowlist, model tier and turn budget stay in one place.
///
/// Transport-agnostic. A gateway parses inbound text and asks [BotRouter]
/// which specialists may take a turn.
library;

import 'agent_team.dart';

/// Chat-facing binding of an [AgentSpec].
class BotBinding {
  const BotBinding({
    required this.handle,
    required this.agentId,
    this.enabled = true,
  });

  /// Canonical handle: lowercase, no leading '@'.
  final String handle;
  final String agentId;
  final bool enabled;

  static final RegExp _valid = RegExp(r'^[a-z0-9][a-z0-9_-]{0,31}$');

  /// Canonical form of [raw], or null when it cannot be a handle.
  static String? canonicalHandle(String raw) {
    final lower = raw.trim().toLowerCase();
    final bare = lower.startsWith('@') ? lower.substring(1) : lower;
    return _valid.hasMatch(bare) ? bare : null;
  }

  Map<String, dynamic> toJson() => {
        'handle': handle,
        'agent_id': agentId,
        'enabled': enabled,
      };

  factory BotBinding.fromJson(Map<String, dynamic> json) {
    final handle = canonicalHandle('${json['handle']}');
    if (handle == null) {
      throw ArgumentError('invalid bot handle: ${json['handle']}');
    }
    return BotBinding(
      handle: handle,
      agentId: '${json['agent_id'] ?? ''}',
      enabled: json['enabled'] != false,
    );
  }
}

/// Handles bound to team members. Persistence is the caller's concern.
class BotRegistry {
  BotRegistry(this.agents);

  final AgentRegistry agents;
  final Map<String, BotBinding> _bindings = {};

  int get length => _bindings.length;

  List<BotBinding> get bindings => _bindings.values.toList(growable: false);

  /// Binds [binding], rejecting unknown handles and unknown agent ids.
  void bind(BotBinding binding) {
    final handle = BotBinding.canonicalHandle(binding.handle);
    if (handle == null) {
      throw ArgumentError('invalid bot handle: ${binding.handle}');
    }
    if (agents.get(binding.agentId) == null) {
      throw ArgumentError('unknown agent id: ${binding.agentId}');
    }
    _bindings[handle] = BotBinding(
      handle: handle,
      agentId: binding.agentId,
      enabled: binding.enabled,
    );
  }

  bool unbind(String handle) =>
      _bindings.remove(BotBinding.canonicalHandle(handle) ?? '') != null;

  BotBinding? bindingFor(String handle) =>
      _bindings[BotBinding.canonicalHandle(handle) ?? ''];

  /// Enabled binding target, or null when absent or disabled.
  AgentSpec? resolve(String handle) {
    final binding = bindingFor(handle);
    if (binding == null || !binding.enabled) {
      return null;
    }
    return agents.get(binding.agentId);
  }
}

/// Extracts bot handles from human text.
class MentionParser {
  static final RegExp _fence = RegExp(r'```.*?```', dotAll: true);
  static final RegExp _inline = RegExp(r'`[^`\n]*`');
  static final RegExp _mention =
      RegExp(r'(?<![\w@])@([a-zA-Z0-9][a-zA-Z0-9_-]{0,31})');

  /// Broadcast pseudo-mentions are never bots.
  static const Set<String> ignored = <String>{'everyone', 'here', 'all'};

  static List<String> parse(String text) {
    final clean = text.replaceAll(_fence, ' ').replaceAll(_inline, ' ');
    final out = <String>[];
    for (final match in _mention.allMatches(clean)) {
      final handle = BotBinding.canonicalHandle(match.group(1)!);
      if (handle == null || ignored.contains(handle)) {
        continue;
      }
      if (!out.contains(handle)) {
        out.add(handle);
      }
    }
    return out;
  }
}

/// Why routing stopped, so a gateway can log instead of guessing.
enum BotRouteDecision { ok, noMention, selfTarget, hopLimit, hostTools }

class BotRoute {
  const BotRoute(this.decision, this.targets, {this.refused = const []});

  final BotRouteDecision decision;
  final List<AgentSpec> targets;

  /// Handles skipped because they would inherit the host tool registry.
  final List<String> refused;

  bool get allowed => decision == BotRouteDecision.ok && targets.isNotEmpty;
}

/// Decides which specialists answer one inbound group message.
class BotRouter {
  const BotRouter({
    required this.registry,
    this.maxHops = 3,
    this.maxTurnsPerMessage = 6,
    this.allowHostToolInheritance = false,
  });

  final BotRegistry registry;

  /// Bot-to-bot depth. A human message is hop 0.
  final int maxHops;
  final int maxTurnsPerMessage;

  /// [AgentSpec.toolAllowlist] being empty means the member inherits the
  /// host tool registry. In a group chat that would let any member reach
  /// host tools through a bot, so it is refused unless opted in.
  final bool allowHostToolInheritance;

  BotRoute route({
    required String text,
    required String senderHandle,
    int hop = 0,
    bool senderIsBot = false,
  }) {
    if (senderIsBot && hop >= maxHops) {
      return const BotRoute(BotRouteDecision.hopLimit, <AgentSpec>[]);
    }
    final sender = BotBinding.canonicalHandle(senderHandle) ?? '';
    final handles = MentionParser.parse(text);
    if (handles.isEmpty) {
      return const BotRoute(BotRouteDecision.noMention, <AgentSpec>[]);
    }
    final targets = <AgentSpec>[];
    final refused = <String>[];
    var sawSelf = false;
    for (final handle in handles) {
      if (handle == sender) {
        sawSelf = true;
        continue;
      }
      final spec = registry.resolve(handle);
      if (spec == null) {
        continue;
      }
      if (spec.toolAllowlist == null || (!allowHostToolInheritance && spec.toolAllowlist!.isEmpty)) {
        refused.add(handle);
        continue;
      }
      targets.add(spec);
      if (targets.length >= maxTurnsPerMessage) {
        break;
      }
    }
    if (targets.isEmpty) {
      if (refused.isNotEmpty) {
        return BotRoute(
          BotRouteDecision.hostTools,
          const <AgentSpec>[],
          refused: refused,
        );
      }
      return BotRoute(
        sawSelf ? BotRouteDecision.selfTarget : BotRouteDecision.noMention,
        const <AgentSpec>[],
      );
    }
    return BotRoute(BotRouteDecision.ok, targets, refused: refused);
  }
}

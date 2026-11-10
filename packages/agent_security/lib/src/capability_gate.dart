import 'package:agent_core/agent_core.dart';

/// Capability check after matrix gate (PRD §12).
///
/// High-impact tools require a short-lived capability id in
/// `call.args['_capability_id']`. Missing id → `needsConfirm` (caller mints
/// after user approval). Valid id → allow without re-prompt.
class CapabilityAwareGate implements PermissionGate {
  CapabilityAwareGate({
    required this.inner,
    required this.validateCapability,
    this.requireCapabilityFor = const {
      'shell',
      'write_file',
      'patch_file',
      'http_request',
    },
    this.requiresCapability,
  });

  final PermissionGate inner;
  final String? Function(String capabilityId, ToolCall call, Session session)
      validateCapability;
  final Set<String> requireCapabilityFor;
  final bool Function(ToolCall call)? requiresCapability;

  @override
  Future<PermissionResult> check(ToolCall call, Session session) async {
    final needsCap = requireCapabilityFor.contains(call.name) ||
        (requiresCapability?.call(call) ?? false);
    final rawCapabilityId = call.args['_capability_id'];
    if (rawCapabilityId != null && rawCapabilityId is! String) {
      return const PermissionResult(
        PermissionVerdict.denied,
        reason: 'capability id has invalid type',
      );
    }
    final capId = rawCapabilityId as String?;

    if (needsCap && capId != null && capId.isNotEmpty) {
      final err = validateCapability(capId, call, session);
      if (err != null) {
        return PermissionResult(PermissionVerdict.denied, reason: err);
      }
      // Re-evaluate the live policy after approval. The capability satisfies
      // only the confirmation requirement; it must not bypass a newly active
      // deny rule, changed risk classification, or dynamic policy condition.
      final policyCall = ToolCall(
        id: call.id,
        name: call.name,
        args: Map<String, dynamic>.from(call.args)..remove('_capability_id'),
      );
      final currentPolicy = await inner.check(policyCall, session);
      if (currentPolicy.verdict == PermissionVerdict.denied) {
        return currentPolicy;
      }
      // A valid, one-shot capability is the user's approval for this exact
      // call; suppress only the repeated confirmation prompt.
      return const PermissionResult(PermissionVerdict.allowed);
    }

    final base = await inner.check(call, session);
    if (base.verdict == PermissionVerdict.denied) return base;

    if (needsCap && (capId == null || capId.isEmpty)) {
      return PermissionResult(
        PermissionVerdict.needsConfirm,
        reason: 'capability required for ${call.name}',
      );
    }
    return base;
  }
}

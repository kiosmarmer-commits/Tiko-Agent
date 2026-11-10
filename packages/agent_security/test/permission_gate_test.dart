import 'package:agent_core/agent_core.dart';
import 'package:agent_security/agent_security.dart';
import 'package:test/test.dart';

void main() {
  final session = Session(id: 's', channel: 'cli', userKey: 'u');

  test('low risk allowed in ask mode', () async {
    final gate = MatrixPermissionGate(mode: PermissionMode.ask);
    final r = await gate.check(
      const ToolCall(id: '1', name: 'datetime', args: {}),
      session,
    );
    expect(r.verdict, PermissionVerdict.allowed);
  });

  test('high risk shell outside allowlist denied', () async {
    final gate = MatrixPermissionGate(mode: PermissionMode.ask);
    final r = await gate.check(
      const ToolCall(id: '1', name: 'shell', args: {'cmd': 'rm -rf /'}),
      session,
    );
    expect(r.verdict, PermissionVerdict.denied);
  });

  test('high risk shell metachar denied', () async {
    final gate = MatrixPermissionGate(mode: PermissionMode.ask);
    final r = await gate.check(
      const ToolCall(
        id: '1',
        name: 'shell',
        args: {'cmd': 'ls; cat /etc/passwd'},
      ),
      session,
    );
    expect(r.verdict, PermissionVerdict.denied);
  });

  test('high risk needs confirm when callback absent', () async {
    final gate = MatrixPermissionGate(mode: PermissionMode.ask);
    final r = await gate.check(
      const ToolCall(id: '1', name: 'shell', args: {'cmd': 'ls'}),
      session,
    );
    expect(r.verdict, PermissionVerdict.needsConfirm);
  });

  test('high risk confirmed via callback', () async {
    final gate = MatrixPermissionGate(
      mode: PermissionMode.ask,
      onConfirmRequest: (call, sess) async => true,
    );
    final r = await gate.check(
      const ToolCall(id: '1', name: 'shell', args: {'cmd': 'ls'}),
      session,
    );
    expect(r.verdict, PermissionVerdict.allowed);
  });

  test('mode deny blocks everything medium+', () async {
    final gate = MatrixPermissionGate(mode: PermissionMode.deny);
    final r = await gate.check(
      const ToolCall(id: '1', name: 'write_file', args: {'path': 'a'}),
      session,
    );
    expect(r.verdict, PermissionVerdict.denied);
  });

  test('safe mode requires approval and a one-shot capability for write tools', () async {
    final state = SafetyState()..enableSafeMode();
    final gate = SafetyPermissionGate(
      CapabilityAwareGate(
        inner: MatrixPermissionGate(mode: PermissionMode.ask),
        validateCapability: (id, call, session) =>
            id == 'permit-1' && session.id == 's' && call.name == 'write_file'
                ? null
                : 'invalid capability',
        requiresCapability: (call) =>
            !SafetyPermissionGate.safeModeTools.contains(call.name),
      ),
      state,
    );

    final safeRead = await gate.check(
      const ToolCall(id: 'read', name: 'read_file', args: {'path': 'a.txt'}),
      session,
    );
    expect(safeRead.verdict, PermissionVerdict.allowed);

    final beforeApproval = await gate.check(
      const ToolCall(id: 'write', name: 'write_file', args: {'path': 'a.txt'}),
      session,
    );
    expect(beforeApproval.verdict, PermissionVerdict.needsConfirm);

    final afterApproval = await gate.check(
      const ToolCall(
        id: 'write',
        name: 'write_file',
        args: {'path': 'a.txt', '_capability_id': 'permit-1'},
      ),
      session,
    );
    expect(afterApproval.verdict, PermissionVerdict.allowed);
  });

  test('valid capability cannot override a changed live deny policy', () async {
    final inner = _SwitchingPermissionGate();
    final gate = CapabilityAwareGate(
      inner: inner,
      validateCapability: (_, __, ___) => null,
      requiresCapability: (_) => true,
    );
    const call = ToolCall(
      id: 'write', name: 'write_file',
      args: {'path': 'a.txt', '_capability_id': 'approved'},
    );

    final initiallyApproved = await gate.check(call, session);
    expect(initiallyApproved.verdict, PermissionVerdict.allowed);

    inner.denied = true;
    final afterPolicyChange = await gate.check(call, session);
    expect(afterPolicyChange.verdict, PermissionVerdict.denied);
  });

  test('panic mode still blocks write tools even with a capability', () async {
    final state = SafetyState()..triggerPanic();
    final gate = SafetyPermissionGate(
      CapabilityAwareGate(
        inner: MatrixPermissionGate(mode: PermissionMode.ask),
        validateCapability: (_, __, ___) => null,
        requiresCapability: (_) => true,
      ),
      state,
    );
    final result = await gate.check(
      const ToolCall(
        id: 'write',
        name: 'write_file',
        args: {'path': 'a.txt', '_capability_id': 'permit'},
      ),
      session,
    );
    expect(result.verdict, PermissionVerdict.denied);
  });

}


class _SwitchingPermissionGate implements PermissionGate {
  bool denied = false;

  @override
  Future<PermissionResult> check(ToolCall call, Session session) async {
    if (denied) {
      return const PermissionResult(
        PermissionVerdict.denied,
        reason: 'policy changed after approval',
      );
    }
    return const PermissionResult(PermissionVerdict.needsConfirm);
  }
}

import 'package:agent_core/agent_core.dart';
import 'package:agent_security/agent_security.dart';
import 'package:test/test.dart';

void main() {
  final session = Session(id: 's', channel: 'cli', userKey: 'u');

  test('guided: medium auto tanpa konfirmasi', () async {
    final gate = MatrixPermissionGate(mode: PermissionMode.guided);
    final r = await gate.check(
      const ToolCall(id: '1', name: 'write_file', args: {}),
      session,
    );
    expect(r.verdict, PermissionVerdict.allowed);
  });

  test('guided: high non-shell tetap dikonfirmasi (callback)', () async {
    var asked = 0;
    final gate = MatrixPermissionGate(
      mode: PermissionMode.guided,
      onConfirmRequest: (call, sess) async {
        asked++;
        return true;
      },
    );
    final r = await gate.check(
      const ToolCall(id: '1', name: 'http_request', args: {}),
      session,
    );
    expect(r.verdict, PermissionVerdict.allowed);
    expect(asked, 1);
  });

  test('guided: high tanpa callback -> needsConfirm (fail-closed)', () async {
    final gate = MatrixPermissionGate(mode: PermissionMode.guided);
    final r = await gate.check(
      const ToolCall(id: '1', name: 'http_request', args: {}),
      session,
    );
    expect(r.verdict, PermissionVerdict.needsConfirm);
  });

  test('guided: shell di dalam allowlist lolos tanpa prompt', () async {
    final gate = MatrixPermissionGate(
      mode: PermissionMode.guided,
      shellAllowlist: const ['ls', 'dart test'],
    );
    final r = await gate.check(
      const ToolCall(id: '1', name: 'shell', args: {'cmd': 'dart test foo'}),
      session,
    );
    expect(r.verdict, PermissionVerdict.allowed);
  });

  test('guided: shell di luar allowlist dikonfirmasi (bukan ditolak)', () async {
    final gate = MatrixPermissionGate(
      mode: PermissionMode.guided,
      onConfirmRequest: (call, sess) async => true,
    );
    final r = await gate.check(
      const ToolCall(id: '1', name: 'shell', args: {'cmd': 'trash data/'}),
      session,
    );
    expect(r.verdict, PermissionVerdict.allowed);
  });

  test('guided: shell metachar tetap ditolak', () async {
    final gate = MatrixPermissionGate(mode: PermissionMode.guided);
    final r = await gate.check(
      const ToolCall(id: '1', name: 'shell', args: {'cmd': 'ls; rm -rf /'}),
      session,
    );
    expect(r.verdict, PermissionVerdict.denied);
  });

  test('guided: medium taint jalur C-03 baseline tak berubah', () async {
    final gate = MatrixPermissionGate(
      mode: PermissionMode.guided,
      taint: TaintTracker(),
      onConfirmRequest: (call, sess) async => true,
    );
    final before = await gate.check(
      const ToolCall(id: '1', name: 'write_file', args: {}),
      session,
    );
    expect(before.verdict, PermissionVerdict.allowed);
  });

  test('riskOverrides: menurunkan label risiko tool', () async {
    final gate = MatrixPermissionGate(
      mode: PermissionMode.guided,
      riskOverrides: const {'verify_project': 'medium'},
    );
    final r = await gate.check(
      const ToolCall(id: '1', name: 'verify_project', args: {}),
      session,
    );
    expect(r.verdict, PermissionVerdict.allowed);
  });

  test('riskOverrides: label tidak valid diabaikan (fail-closed)', () async {
    final gate = MatrixPermissionGate(
      mode: PermissionMode.guided,
      riskOverrides: const {'verify_project': 'nope'},
      onConfirmRequest: (call, sess) async => true,
    );
    final r = await gate.check(
      const ToolCall(id: '1', name: 'verify_project', args: {}),
      session,
    );
    expect(r.verdict, PermissionVerdict.allowed);
    // 'nope' tidak dipakai: risk via unknown-name floor = high → confirm.
  });

  test('riskOverrides: menaikkan risiko juga didukung', () async {
    final gate = MatrixPermissionGate(
      mode: PermissionMode.guided,
      riskOverrides: const {'datetime': 'high'},
    );
    final r = await gate.check(
      const ToolCall(id: '1', name: 'datetime', args: {}),
      session,
    );
    expect(r.verdict, PermissionVerdict.needsConfirm);
  });

  test('mode ask lama tidak berubah (regresi)', () async {
    final gate = MatrixPermissionGate(mode: PermissionMode.ask);
    final r = await gate.check(
      const ToolCall(id: '1', name: 'write_file', args: {}),
      session,
    );
    expect(r.verdict, PermissionVerdict.needsConfirm);
  });
}

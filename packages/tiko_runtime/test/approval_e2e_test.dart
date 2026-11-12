import 'dart:io';

import 'package:agent_core/agent_core.dart';
import 'package:test/test.dart';
import 'package:tiko_runtime/tiko_runtime.dart';

/// Test double that forces the confirm phase for every tool call, then
/// accepts it once a capability token has been issued by the approval path.
///
/// This isolates the P0-3 subject — the runtime's broker-backed confirm
/// wiring — from the matrix risk classification covered by agent_security.
class _AlwaysConfirmGate implements PermissionGate {
  const _AlwaysConfirmGate();

  @override
  Future<PermissionResult> check(ToolCall call, Session session) async {
    if (call.args['_capability_id'] is String) {
      return const PermissionResult(PermissionVerdict.allowed);
    }
    return const PermissionResult(
      PermissionVerdict.needsConfirm,
      reason: 'test gate: confirm required',
    );
  }
}

void main() {
  late Directory temp;
  late TikoRuntime runtime;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('tiko_approval_e2e_');
    final config = File('${temp.path}/agent.yaml');
    await config.writeAsString('''
providers:
  chat:
    mock:
      type: mock
      scenario: single_tool
''');
    runtime = await TikoRuntime.create(configPath: config.path);
  });

  tearDown(() async {
    await runtime.approvals.close();
    await runtime.events.close();
    await temp.delete(recursive: true);
  });

  Future<ChatRunResult> runTurn(
    String sessionId, {
    required Future<bool> Function(String approvalId)? onPrompt,
  }) =>
      runtime.chatWithStatus(
        'jam berapa sekarang?',
        sessionId: sessionId,
        channel: 'telegram',
        userKey: 'tester',
        gateOverride: const _AlwaysConfirmGate(),
        confirm: onPrompt == null
            ? null
            : (call, sess, approvalId) => onPrompt(approvalId),
      );

  test('approval ID tunggal: keputusan dari surface lain menyelesaikan '
      'permintaan yang sama tanpa keputusan ganda', () async {
    String? promptApprovalId;
    final result = await runTurn(
      'e2e:approval',
      onPrompt: (approvalId) async {
        promptApprovalId = approvalId;
        // Simulasi user menekan tombol approve di surface lain (web/Flutter)
        // sebelum menutup prompt channel: keputusan lewat broker bersama.
        final decided = await runtime.decideApproval(
          approvalId,
          approve: true,
          actor: 'web',
        );
        expect(decided, isNotNull);
        return true;
      },
    );

    expect(result.success, isTrue);
    expect(promptApprovalId, startsWith('apr_'));

    final history = await runtime.approvals.all();
    final mine = history.where((r) => r.id == promptApprovalId).toList();
    expect(mine, hasLength(1));
    expect(mine.single.state, ApprovalState.approved);
    expect(mine.single.actor, 'web');

    // Replay dari surface lain tidak mengubah keputusan (single source of truth).
    final replay = await runtime.decideApproval(promptApprovalId!, approve: false);
    expect(replay, isNull);
    final after = await runtime.approvals.all();
    expect(
      after.singleWhere((r) => r.id == promptApprovalId).state,
      ApprovalState.approved,
    );
  });

  test('penolakan dari channel tercatat di broker dan tool tidak dieksekusi',
      () async {
    String? promptApprovalId;
    final result = await runTurn(
      'e2e:deny',
      onPrompt: (approvalId) async {
        promptApprovalId = approvalId;
        return false;
      },
    );

    // Tool ditolak: turn ditandai gagal, broker mencatat penolakan.
    expect(result.success, isFalse);
    final mine = (await runtime.approvals.all())
        .singleWhere((r) => r.id == promptApprovalId);
    expect(mine.state, ApprovalState.denied);
    expect(mine.actor, 'confirm_fn');
  });

  test('channel tanpa UI tetap fail-closed melalui broker yang sama', () async {
    // TTL pendek agar jalur timeout headless teruji cepat.
    runtime.approvals = ApprovalBroker(
      runtime.approvals.path,
      requestTtl: const Duration(milliseconds: 400),
    );
    await runtime.approvals.load();

    final result = await runtime.chatWithStatus(
      'jam berapa sekarang?',
      sessionId: 'e2e:headless',
      channel: 'http',
      userKey: 'tester',
      gateOverride: const _AlwaysConfirmGate(),
    );

    // Tidak ada keputusan: approval kedaluwarsa dan tool tidak dijalankan.
    expect(result.success, isFalse);
    final history = await runtime.approvals.all();
    final mine = history.where((r) => r.sessionId == 'e2e:headless').toList();
    expect(mine, hasLength(1));
    expect(mine.single.state, ApprovalState.expired);
    expect(mine.single.tool, 'datetime');
  });
}

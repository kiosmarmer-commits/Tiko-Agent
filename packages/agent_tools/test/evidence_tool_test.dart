import 'package:agent_core/agent_core.dart';
import 'package:agent_tools/agent_tools.dart';
import 'package:test/test.dart';

void main() {
  ToolContext ctx() => ToolContext(
        session: Session(id: 's1', channel: 'cli', userKey: 'local'),
        workspacePath: '.',
      );

  test('claim menolak bukti yang tidak dikenal', () async {
    final ledger = EvidenceLedger();
    ledger.recordCall('c1', 'shell', 'ok');
    final res = await ClaimTool(ledger: ledger).run({
      'text': 'tes lulus',
      'evidence': ['c1', 'c9'],
    }, ctx());
    expect(res.isError, isTrue);
    expect(res.content, contains('c9'));
  });

  test('claim mencatat klaim dengan bukti valid', () async {
    final ledger = EvidenceLedger();
    ledger.recordCall('c1', 'shell', 'exit: 0');
    final res = await ClaimTool(ledger: ledger).run({
      'text': 'build sukses',
      'evidence': ['c1'],
    }, ctx());
    expect(res.isError, isFalse);
    expect(res.content, contains('#1'));
  });

  test('verify_claims melaporkan klaim kedaluwarsa', () async {
    final ledger = EvidenceLedger();
    ledger.recordCall('c1', 'shell', 'exit: 0');
    await ClaimTool(ledger: ledger).run({
      'text': 'tes lulus',
      'evidence': ['c1'],
    }, ctx());
    ledger.recordCall('c1', 'shell', 'exit: 1');
    final res = await VerifyClaimsTool(ledger: ledger).run({}, ctx());
    expect(res.isError, isTrue);
    expect(res.content, contains('FAIL'));
    expect(res.content, contains('kedaluwarsa'));
  });

  test('verify_claims tanpa klaim mengembalikan error', () async {
    final res = await VerifyClaimsTool(ledger: EvidenceLedger())
        .run({}, ctx());
    expect(res.isError, isTrue);
  });
}

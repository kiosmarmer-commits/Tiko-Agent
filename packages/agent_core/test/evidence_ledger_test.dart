import 'package:agent_core/agent_core.dart';
import 'package:test/test.dart';

void main() {
  test('hash stabil dan sensitif terhadap perubahan output', () {
    expect(evidenceHash('ok'), equals(evidenceHash('ok')));
    expect(evidenceHash('ok'), isNot(equals(evidenceHash('oke'))));
  });

  test('recordCall menghasilkan ID fallback untuk callId kosong', () {
    final l = EvidenceLedger();
    final a = l.recordCall('', 'shell', 'exit: 0');
    final b = l.recordCall('', 'shell', 'exit: 1');
    expect(a, equals('call-1'));
    expect(b, equals('call-2'));
    expect(l.callCount, equals(2));
  });

  test('addClaim menolak ID bukti yang tidak dikenal', () {
    final l = EvidenceLedger();
    l.recordCall('c1', 'shell', 'ok');
    final unknown = l.addClaim('tes lulus', ['c1', 'nope']);
    expect(unknown, equals(['nope']));
    expect(l.claimCount, equals(0));
  });

  test('verify menandai bukti kedaluwarsa saat output berubah', () {
    final l = EvidenceLedger();
    l.recordCall('c1', 'shell', 'exit: 0');
    expect(l.addClaim('tes lulus', ['c1']), isNull);
    l.recordCall('c1', 'shell', 'exit: 1');
    final v = l.verify();
    expect(v.single.supported, isFalse);
    expect(v.single.stale, equals(['c1']));
  });

  test('verify mendukung klaim dengan bukti utuh', () {
    final l = EvidenceLedger();
    l.recordCall('c1', 'grep', '3 cocok');
    l.addClaim('grep menemukan 3 cocok', ['c1']);
    l.recordCall('c2', 'datetime', '2026-11-08');
    final v = l.verify();
    expect(v.single.supported, isTrue);
    expect(v.single.missing, isEmpty);
    expect(v.single.stale, isEmpty);
  });
}

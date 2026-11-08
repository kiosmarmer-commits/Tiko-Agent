import 'package:agent_calc/agent_calc.dart';

/// Benchmark biaya sandbox isolate (TASK-CALC-36, target Termux):
/// membandingkan evaluasi langsung vs via [CalcSandbox] untuk
/// ekspresi ringan, lalu mencetak p50/p95 mikrodetik.
///
/// Jalankan: dart run tool/bench_isolate.dart [iterasi]
Future<void> main(List<String> args) async {
  final n = args.isEmpty ? 50 : int.tryParse(args[0]) ?? 50;
  const sandbox = CalcSandbox();
  const engine = CalcEngine();

  final directUs = <int>[];
  final sandboxUs = <int>[];
  for (var i = 0; i < n; i++) {
    final sw = Stopwatch()..start();
    final r1 = engine.evaluate('2+3');
    sw.stop();
    if (r1.ok) directUs.add(sw.elapsedMicroseconds);

    final sw2 = Stopwatch()..start();
    final r2 = await sandbox.evaluate('2+3');
    sw2.stop();
    if (r2.ok) sandboxUs.add(sw2.elapsedMicroseconds);
  }
  print('iterasi: $n (ok: ${directUs.length}/${sandboxUs.length})');
  print('langsung p50=${_p(directUs, 50)}us p95=${_p(directUs, 95)}us');
  print('sandbox  p50=${_p(sandboxUs, 50)}us p95=${_p(sandboxUs, 95)}us');
}

int _p(List<int> xs, int pct) {
  if (xs.isEmpty) return 0;
  final s = [...xs]..sort();
  var i = (s.length * pct / 100).floor();
  if (i >= s.length) i = s.length - 1;
  return s[i];
}

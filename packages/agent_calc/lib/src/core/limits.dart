/// Batas sumber daya evaluasi (CALC-ARC-06). Semua nilai bisa diganti
/// lewat konfigurasi; default aman untuk perangkat Termux.
final class CalcLimits {
  const CalcLimits({
    this.maxExpressionLength = 2000,
    this.maxAstDepth = 64,
    this.maxPowerExponent = 10000,
    this.maxResultDigits = 10000,
    this.maxFactorial = 5000,
    this.maxListLength = 100000,
    this.maxHorizon = 365,
    this.timeoutMs = 2000,
  });

  final int maxExpressionLength;
  final int maxAstDepth;
  final int maxPowerExponent;
  final int maxResultDigits;
  final int maxFactorial;
  final int maxListLength;
  final int maxHorizon;
  final int timeoutMs;

  static const CalcLimits defaults = CalcLimits();
}

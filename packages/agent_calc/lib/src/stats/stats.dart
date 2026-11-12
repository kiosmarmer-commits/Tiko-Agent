import '../core/errors.dart';
import '../core/numeric.dart';
import '../core/rounding.dart';
import '../eval/evaluator.dart';

/// Statistik deskriptif eksak (TASK-CALC-16..17). Dua lolos dengan Dec;
/// stabilisasi Welford tidak diperlukan karena aritmetika sudah eksak.
final class CalcStats {
  CalcStats._();

  static void _check(List<Dec> a, String name, EvalContext ctx) {
    if (a.isEmpty) {
      throw CalcException(
        CalcErrorCodes.syntax,
        'Fungsi $name butuh minimal 1 data',
      );
    }
    if (a.length > ctx.limits.maxListLength) {
      throw const CalcException(
        CalcErrorCodes.limit,
        'Jumlah data melebihi batas',
      );
    }
  }

  static Dec _sum(List<Dec> a) {
    var s = Dec.zero;
    for (final v in a) {
      s += v;
    }
    return s;
  }

  static Dec mean(List<Dec> a, EvalContext ctx) {
    _check(a, 'mean', ctx);
    return _sum(a).divide(
      Dec.fromInt(a.length),
      scale: ctx.scale,
      mode: ctx.rounding,
    );
  }

  static Dec median(List<Dec> a, EvalContext ctx) {
    _check(a, 'median', ctx);
    final sorted = [...a]..sort();
    final n = sorted.length;
    final mid = n ~/ 2;
    if (n.isOdd) return sorted[mid];
    return (sorted[mid - 1] + sorted[mid]).divide(
      Dec.fromInt(2),
      scale: ctx.scale,
      mode: ctx.rounding,
    );
  }

  static Dec variance(
    List<Dec> a,
    EvalContext ctx, {
    required bool sample,
  }) {
    _check(a, sample ? 'var_s' : 'var_p', ctx);
    final n = a.length;
    if (sample && n < 2) {
      throw const CalcException(
        CalcErrorCodes.domain,
        'Varians sampel butuh minimal 2 data',
      );
    }
    final m = mean(a, ctx);
    var ss = Dec.zero;
    for (final x in a) {
      final d = x - m;
      ss += d * d;
    }
    return ss.divide(
      Dec.fromInt(sample ? n - 1 : n),
      scale: ctx.scale,
      mode: ctx.rounding,
    );
  }

  static Dec stdev(
    List<Dec> a,
    EvalContext ctx, {
    required bool sample,
  }) {
    return variance(a, ctx, sample: sample).sqrtAt(ctx.scale);
  }

  /// Persentil interpolasi linear: rank = p/100*(n-1) pada data
  /// terurut (TASK-CALC-17).
  static Dec percentile(List<Dec> data, Dec p, EvalContext ctx) {
    _check(data, 'percentile', ctx);
    if (p.sign < 0 || p.compareTo(Dec.fromInt(100)) > 0) {
      throw const CalcException(
        CalcErrorCodes.domain,
        'Persentil harus 0..100',
      );
    }
    final sorted = [...data]..sort();
    final n = sorted.length;
    if (n == 1) return sorted[0];
    final rank = (p * Dec.fromInt(n - 1)).divide(
      Dec.fromInt(100),
      scale: ctx.scale + 8,
      mode: ctx.rounding,
    );
    final lo = rank.roundTo(0, RoundingMode.down);
    final li = lo.unscaled.toInt();
    if (li >= n - 1) return sorted[n - 1];
    final frac = rank - lo;
    final delta = sorted[li + 1] - sorted[li];
    return (sorted[li] + frac * delta)
        .roundTo(ctx.scale, ctx.rounding)
        .normalized;
  }
}

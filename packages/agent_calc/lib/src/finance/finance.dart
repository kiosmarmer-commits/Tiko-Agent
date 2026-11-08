import '../core/errors.dart';
import '../core/numeric.dart';
import '../eval/evaluator.dart';

/// Fungsi keuangan (TASK-CALC-13..15). Jalur anuitas eksak: pangkat
/// bulat via Dec lalu satu pembagian pada skala konteks. IRR numerik:
/// bisection double 200 iterasi dan menandai approximate pada konteks.
final class CalcFinance {
  CalcFinance._();

  /// Jumlah periode: bulat positif, maksimum 12000.
  static int _periods(Dec d) {
    if (d.sign <= 0 || d.scale != 0) {
      throw const CalcException(
        CalcErrorCodes.domain,
        'Jumlah periode harus bulat positif',
      );
    }
    if (d.unscaled > BigInt.from(12000)) {
      throw const CalcException(
        CalcErrorCodes.limit,
        'Jumlah periode maksimum 12000',
      );
    }
    return d.unscaled.toInt();
  }

  /// Jumlah angsuran terbayar: bulat 0..n.
  static int _paid(Dec d, int n) {
    if (d.sign < 0 || d.scale != 0) {
      throw const CalcException(
        CalcErrorCodes.domain,
        'Jumlah angsuran harus bulat >= 0',
      );
    }
    final k = d.unscaled.toInt();
    if (k > n) {
      throw const CalcException(
        CalcErrorCodes.domain,
        'Jumlah angsuran melebihi tenor',
      );
    }
    return k;
  }

  /// Faktor pertumbuhan (1+i)^n dengan batas digit hasil.
  static Dec _growth(Dec rate, int n, EvalContext ctx) {
    final g = (Dec.one + rate).powInt(n);
    final digits = g.unscaled.abs().toString().length + g.scale;
    if (digits > ctx.limits.maxResultDigits) {
      throw const CalcException(
        CalcErrorCodes.limit,
        'Hasil bunga majemuk melebihi batas digit',
      );
    }
    return g;
  }

  /// Angsuran anuitas: pv*i*g/(g-1), g = (1+i)^n (eksak).
  static Dec pmt(Dec rate, Dec periods, Dec pv, EvalContext ctx) {
    final n = _periods(periods);
    if (rate.isZero) {
      return pv.divide(
        Dec.fromInt(n),
        scale: ctx.scale,
        mode: ctx.rounding,
      );
    }
    final g = _growth(rate, n, ctx);
    return (pv * rate * g).divide(
      g - Dec.one,
      scale: ctx.scale,
      mode: ctx.rounding,
    );
  }

  /// Nilai masa depan anuitas: pmt*(g-1)/i (eksak).
  static Dec annuityFv(Dec rate, Dec periods, Dec pmt, EvalContext ctx) {
    final n = _periods(periods);
    if (rate.isZero) return pmt * Dec.fromInt(n);
    final g = _growth(rate, n, ctx);
    return (pmt * (g - Dec.one)).divide(
      rate,
      scale: ctx.scale,
      mode: ctx.rounding,
    );
  }

  /// Nilai kini anuitas: pmt*(g-1)/(g*i) (eksak).
  static Dec annuityPv(Dec rate, Dec periods, Dec pmt, EvalContext ctx) {
    final n = _periods(periods);
    if (rate.isZero) return pmt * Dec.fromInt(n);
    final g = _growth(rate, n, ctx);
    return (pmt * (g - Dec.one)).divide(
      g * rate,
      scale: ctx.scale,
      mode: ctx.rounding,
    );
  }

  /// Total bunga sepanjang tenor: pmt*n - pv.
  static Dec totalInterest(Dec rate, Dec periods, Dec pv, EvalContext ctx) {
    final n = _periods(periods);
    return pmt(rate, periods, pv, ctx) * Dec.fromInt(n) - pv;
  }

  /// Sisa pinjaman setelah k angsuran.
  static Dec balance(
    Dec rate,
    Dec periods,
    Dec pv,
    Dec paid,
    EvalContext ctx,
  ) {
    final n = _periods(periods);
    final k = _paid(paid, n);
    if (rate.isZero) {
      final p = pv.divide(
        Dec.fromInt(n),
        scale: ctx.scale,
        mode: ctx.rounding,
      );
      return pv - p * Dec.fromInt(k);
    }
    final p = pmt(rate, periods, pv, ctx);
    final gk = _growth(rate, k, ctx);
    final paidOff = (p * (gk - Dec.one)).divide(
      rate,
      scale: ctx.scale,
      mode: ctx.rounding,
    );
    return pv * gk - paidOff;
  }

  /// IRR: bisection NPV pada double. Tanpa akar pada rentang
  /// -99%..1000% memakai CALC_E_NO_CONVERGENCE.
  static Dec irr(List<Dec> args, EvalContext ctx) {
    final cfs = [for (final a in args) _d(a, 'irr')];

    double f(double r) {
      var total = 0.0;
      var factor = 1.0;
      for (final c in cfs) {
        total += c / factor;
        factor *= 1.0 + r;
      }
      return total;
    }

    var lo = -0.99;
    var hi = 10.0;
    var flo = f(lo);
    final fhi = f(hi);
    if (flo == 0.0) return _approx(lo, ctx);
    if (fhi == 0.0) return _approx(hi, ctx);
    if (flo * fhi > 0.0) {
      throw const CalcException(
        CalcErrorCodes.noConvergence,
        'IRR tidak ditemukan pada rentang -99%..1000%',
        hint: 'arus kas harus berubah tanda (investasi dan hasil)',
      );
    }
    for (var i = 0; i < 200; i++) {
      final mid = (lo + hi) / 2;
      final fm = f(mid);
      if (fm == 0.0) return _approx(mid, ctx);
      if (flo * fm <= 0.0) {
        hi = mid;
      } else {
        lo = mid;
        flo = fm;
      }
    }
    return _approx((lo + hi) / 2, ctx);
  }

  static double _d(Dec x, String name) {
    final s = x.toString();
    if (s.length > 320) {
      throw CalcException(
        CalcErrorCodes.domain,
        'Nilai terlalu besar untuk fungsi $name',
      );
    }
    final v = double.tryParse(s);
    if (v == null) {
      throw CalcException(
        CalcErrorCodes.domain,
        'Nilai tidak terdefinisi untuk fungsi $name',
      );
    }
    return v;
  }

  static Dec _approx(double v, EvalContext ctx) {
    if (v.isNaN || v.isInfinite) {
      throw const CalcException(
        CalcErrorCodes.domain,
        'IRR tidak terdefinisi',
      );
    }
    ctx.approximate = true;
    return Dec.fromApproxDouble(v);
  }
}

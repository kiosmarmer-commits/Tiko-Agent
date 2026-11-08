import 'dart:math' as math;

import '../core/errors.dart';
import '../core/limits.dart';
import '../core/numeric.dart';
import '../core/rounding.dart';
import '../finance/finance.dart';
import 'evaluator.dart';

/// Fungsi evaluator (CALC-MAT-05b). Jalur eksak memakai Dec; jalur
/// transendental memakai double, 15 digit signifikan, dan menandai
/// approximate pada konteks.
typedef CalcFn = Dec Function(List<Dec> args, EvalContext ctx);

final class CalcFunctions {
  CalcFunctions._();

  static void _need(List<Dec> a, String name, int min, [int? max]) {
    if (a.length < min || (max != null && a.length > max)) {
      final range =
          max == null ? 'minimal $min' : (min == max ? '$min' : '$min-$max');
      throw CalcException(
        CalcErrorCodes.syntax,
        'Fungsi $name butuh $range argumen',
      );
    }
  }

  static int _asInt(Dec d, String name) {
    if (d.scale != 0) {
      throw CalcException(
        CalcErrorCodes.domain,
        'Fungsi $name butuh bilangan bulat',
      );
    }
    if (d.unscaled.abs() > BigInt.from(1000000000)) {
      throw const CalcException(
        CalcErrorCodes.limit,
        'Argumen bulat terlalu besar',
      );
    }
    return d.unscaled.toInt();
  }

  static Dec _approx(double v, EvalContext ctx) {
    if (v.isNaN || v.isInfinite) {
      throw const CalcException(
        CalcErrorCodes.domain,
        'Hasil tidak terdefinisi (di luar domain)',
      );
    }
    ctx.approximate = true;
    return Dec.fromApproxDouble(v);
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

  static double _angle(Dec x, EvalContext ctx) {
    final v = _d(x, 'trigonometri');
    return ctx.angleUnit == 'deg' ? v * math.pi / 180 : v;
  }

  /// Semantik pangkat `^` dan fungsi pow.
  static Dec power(Dec base, Dec exp, EvalContext ctx) {
    if (exp.scale == 0) {
      final e = exp.unscaled;
      if (e.abs() > BigInt.from(ctx.limits.maxPowerExponent)) {
        throw const CalcException(
          CalcErrorCodes.limit,
          'Pangkat melebihi batas',
        );
      }
      Dec r;
      if (e.isNegative) {
        if (base.isZero) {
          throw const CalcException(
            CalcErrorCodes.domain,
            'Nol pangkat negatif tidak terdefinisi',
          );
        }
        r = Dec.one.divide(
          base.powInt(-e.toInt()),
          scale: ctx.scale,
          mode: ctx.rounding,
        );
      } else {
        r = base.powInt(e.toInt());
      }
      final digits = r.unscaled.abs().toString().length + r.scale;
      if (digits > ctx.limits.maxResultDigits) {
        throw const CalcException(
          CalcErrorCodes.limit,
          'Hasil pangkat melebihi batas digit',
        );
      }
      return r;
    }
    final b = _d(base, 'pow');
    final e = _d(exp, 'pow');
    return _approx(math.pow(b, e).toDouble(), ctx);
  }

  static BigInt factorial(int n, CalcLimits limits) {
    if (n < 0) {
      throw const CalcException(
        CalcErrorCodes.domain,
        'Faktorial bilangan negatif',
      );
    }
    if (n > limits.maxFactorial) {
      throw CalcException(
        CalcErrorCodes.limit,
        'Faktorial melebihi batas (maksimum ${limits.maxFactorial})',
      );
    }
    var r = BigInt.one;
    for (var i = 2; i <= n; i++) {
      r *= BigInt.from(i);
    }
    return r;
  }

  static BigInt ncr(int n, int r) {
    if (n < 0 || r < 0 || r > n) {
      throw const CalcException(
        CalcErrorCodes.domain,
        'nCr: butuh 0 <= r <= n',
      );
    }
    final k = r < n - r ? r : n - r;
    var result = BigInt.one;
    for (var i = 1; i <= k; i++) {
      result = result * BigInt.from(n - k + i) ~/ BigInt.from(i);
    }
    return result;
  }

  static BigInt npr(int n, int r) {
    if (n < 0 || r < 0 || r > n) {
      throw const CalcException(
        CalcErrorCodes.domain,
        'nPr: butuh 0 <= r <= n',
      );
    }
    var result = BigInt.one;
    for (var i = 0; i < r; i++) {
      result *= BigInt.from(n - i);
    }
    return result;
  }

  static Dec _sum(List<Dec> a) {
    var s = Dec.zero;
    for (final v in a) {
      s += v;
    }
    return s;
  }

  static Dec _round(List<Dec> a, String name, RoundingMode mode) {
    _need(a, name, 1, 2);
    final n = a.length > 1 ? _asInt(a[1], name) : 0;
    if (n < 0) {
      throw CalcException(
        CalcErrorCodes.domain,
        'Fungsi $name butuh jumlah desimal >= 0',
      );
    }
    return a[0].roundTo(n, mode);
  }

  static final Map<String, CalcFn> all = {
    'abs': (a, _) {
      _need(a, 'abs', 1, 1);
      return a[0].abs();
    },
    'sign': (a, _) {
      _need(a, 'sign', 1, 1);
      return Dec.fromInt(a[0].sign);
    },
    'floor': (a, _) => _round(a, 'floor', RoundingMode.floor),
    'ceil': (a, _) => _round(a, 'ceil', RoundingMode.ceiling),
    'trunc': (a, _) => _round(a, 'trunc', RoundingMode.down),
    // DEC-OPEN-01 diputuskan: round() default half_up (kebiasaan sekolah);
    // varian eksplisit tersedia lewat round_half_even / round_half_up.
    'round': (a, _) => _round(a, 'round', RoundingMode.halfUp),
    'round_half_even': (a, _) => _round(a, 'round_half_even', RoundingMode.halfEven),
    'round_half_up': (a, _) => _round(a, 'round_half_up', RoundingMode.halfUp),
    'min': (a, _) {
      _need(a, 'min', 1);
      var m = a[0];
      for (final v in a.skip(1)) {
        if (v.compareTo(m) < 0) m = v;
      }
      return m;
    },
    'max': (a, _) {
      _need(a, 'max', 1);
      var m = a[0];
      for (final v in a.skip(1)) {
        if (v.compareTo(m) > 0) m = v;
      }
      return m;
    },
    'sum': (a, _) {
      _need(a, 'sum', 1);
      return _sum(a);
    },
    'avg': (a, ctx) {
      _need(a, 'avg', 1);
      return _sum(a).divide(
        Dec.fromInt(a.length),
        scale: ctx.scale,
        mode: ctx.rounding,
      );
    },
    'pow': (a, ctx) {
      _need(a, 'pow', 2, 2);
      return power(a[0], a[1], ctx);
    },
    'sqrt': (a, ctx) {
      _need(a, 'sqrt', 1, 1);
      if (a[0].sign < 0) {
        throw const CalcException(
          CalcErrorCodes.domain,
          'Akar bilangan negatif',
        );
      }
      return a[0].sqrtAt(ctx.scale);
    },
    'cbrt': (a, ctx) {
      _need(a, 'cbrt', 1, 1);
      return _approx(math.pow(_d(a[0], 'cbrt'), 1 / 3).toDouble(), ctx);
    },
    'hypot': (a, ctx) {
      _need(a, 'hypot', 2, 2);
      return _approx(
        math.sqrt(
          math.pow(_d(a[0], 'hypot'), 2) + math.pow(_d(a[1], 'hypot'), 2),
        ),
        ctx,
      );
    },
    'exp': (a, ctx) {
      _need(a, 'exp', 1, 1);
      return _approx(math.exp(_d(a[0], 'exp')), ctx);
    },
    'ln': (a, ctx) {
      _need(a, 'ln', 1, 1);
      final x = _d(a[0], 'ln');
      if (x <= 0) {
        throw const CalcException(
          CalcErrorCodes.domain,
          'ln hanya untuk bilangan positif',
        );
      }
      return _approx(math.log(x), ctx);
    },
    'log': (a, ctx) {
      _need(a, 'log', 1, 1);
      final x = _d(a[0], 'log');
      if (x <= 0) {
        throw const CalcException(
          CalcErrorCodes.domain,
          'log hanya untuk bilangan positif',
        );
      }
      return _approx(math.log(x) / math.ln10, ctx);
    },
    'log2': (a, ctx) {
      _need(a, 'log2', 1, 1);
      final x = _d(a[0], 'log2');
      if (x <= 0) {
        throw const CalcException(
          CalcErrorCodes.domain,
          'log2 hanya untuk bilangan positif',
        );
      }
      return _approx(math.log(x) / math.ln2, ctx);
    },
    'sin': (a, ctx) {
      _need(a, 'sin', 1, 1);
      return _approx(math.sin(_angle(a[0], ctx)), ctx);
    },
    'cos': (a, ctx) {
      _need(a, 'cos', 1, 1);
      return _approx(math.cos(_angle(a[0], ctx)), ctx);
    },
    'tan': (a, ctx) {
      _need(a, 'tan', 1, 1);
      return _approx(math.tan(_angle(a[0], ctx)), ctx);
    },
    'asin': (a, ctx) {
      _need(a, 'asin', 1, 1);
      return _approx(math.asin(_d(a[0], 'asin')), ctx);
    },
    'acos': (a, ctx) {
      _need(a, 'acos', 1, 1);
      return _approx(math.acos(_d(a[0], 'acos')), ctx);
    },
    'atan': (a, ctx) {
      _need(a, 'atan', 1, 1);
      return _approx(math.atan(_d(a[0], 'atan')), ctx);
    },
    'atan2': (a, ctx) {
      _need(a, 'atan2', 2, 2);
      return _approx(math.atan2(_d(a[0], 'atan2'), _d(a[1], 'atan2')), ctx);
    },
    'sinh': (a, ctx) {
      _need(a, 'sinh', 1, 1);
      final x = _d(a[0], 'sinh');
      return _approx((math.exp(x) - math.exp(-x)) / 2, ctx);
    },
    'cosh': (a, ctx) {
      _need(a, 'cosh', 1, 1);
      final x = _d(a[0], 'cosh');
      return _approx((math.exp(x) + math.exp(-x)) / 2, ctx);
    },
    'tanh': (a, ctx) {
      _need(a, 'tanh', 1, 1);
      final x = _d(a[0], 'tanh');
      final e2 = math.exp(2 * x);
      return _approx((e2 - 1) / (e2 + 1), ctx);
    },
    'deg': (a, ctx) {
      _need(a, 'deg', 1, 1);
      return _approx(_d(a[0], 'deg') * 180 / math.pi, ctx);
    },
    'rad': (a, ctx) {
      _need(a, 'rad', 1, 1);
      return _approx(_d(a[0], 'rad') * math.pi / 180, ctx);
    },
    'fact': (a, ctx) {
      _need(a, 'fact', 1, 1);
      return Dec.fromBigInt(
        factorial(_asInt(a[0], 'fact'), ctx.limits),
      );
    },
    'gcd': (a, _) {
      _need(a, 'gcd', 2, 2);
      var x = _asInt(a[0], 'gcd').abs();
      var y = _asInt(a[1], 'gcd').abs();
      while (y != 0) {
        final t = x % y;
        x = y;
        y = t;
      }
      return Dec.fromInt(x);
    },
    'lcm': (a, _) {
      _need(a, 'lcm', 2, 2);
      final x = _asInt(a[0], 'lcm').abs();
      final y = _asInt(a[1], 'lcm').abs();
      if (x == 0 || y == 0) return Dec.zero;
      return Dec.fromBigInt(
        BigInt.from(x) ~/ BigInt.from(gcdSmall(x, y)) * BigInt.from(y),
      );
    },
    'ncr': (a, _) {
      _need(a, 'ncr', 2, 2);
      return Dec.fromBigInt(ncr(_asInt(a[0], 'ncr'), _asInt(a[1], 'ncr')));
    },
    'npr': (a, _) {
      _need(a, 'npr', 2, 2);
      return Dec.fromBigInt(npr(_asInt(a[0], 'npr'), _asInt(a[1], 'npr')));
    },
    'mod': (a, _) {
      _need(a, 'mod', 2, 2);
      if (a[1].isZero) {
        throw const CalcException(
          CalcErrorCodes.divZero,
          'Modulo dengan nol',
        );
      }
      return a[0].remainderOf(a[1]);
    },
    // TASK-CALC-13..15: keuangan (CalcFinance).
    'pmt': (a, ctx) {
      _need(a, 'pmt', 3, 3);
      return CalcFinance.pmt(a[0], a[1], a[2], ctx);
    },
    'annuity_fv': (a, ctx) {
      _need(a, 'annuity_fv', 3, 3);
      return CalcFinance.annuityFv(a[0], a[1], a[2], ctx);
    },
    'annuity_pv': (a, ctx) {
      _need(a, 'annuity_pv', 3, 3);
      return CalcFinance.annuityPv(a[0], a[1], a[2], ctx);
    },
    'amortisasi': (a, ctx) {
      _need(a, 'amortisasi', 3, 3);
      return CalcFinance.totalInterest(a[0], a[1], a[2], ctx);
    },
    'sisa': (a, ctx) {
      _need(a, 'sisa', 4, 4);
      return CalcFinance.balance(a[0], a[1], a[2], a[3], ctx);
    },
    'irr': (a, ctx) {
      _need(a, 'irr', 2);
      return CalcFinance.irr(a, ctx);
    },
  };

  static int gcdSmall(int a, int b) {
    while (b != 0) {
      final t = a % b;
      a = b;
      b = t;
    }
    return a;
  }
}

import 'rounding.dart';

/// Bilangan desimal eksak: `value = unscaled * 10^-scale`.
///
/// Hanya boleh dibuat dari String, int, atau BigInt - tidak dari double,
/// karena double sudah nilai biner yang dibulatkan (CALC-MAT-01, REF-21).
/// Pembagian wajib memakai [divide] dengan skala dan mode eksplisit;
/// tidak ada operator `/` tanpa konteks.
final class Dec implements Comparable<Dec> {
  Dec._(this.unscaled, this.scale);

  final BigInt unscaled;
  final int scale; // >= 0

  static final Dec zero = Dec._(BigInt.zero, 0);
  static final Dec one = Dec._(BigInt.one, 0);
  static final BigInt _ten = BigInt.from(10);

  /// Validasi ketat: `[+-]?digits[.digits]`, mis. `12.50`, `.5`, `-3`.
  factory Dec.parse(String s) {
    final t = s.trim();
    var body = t;
    var negative = false;
    if (body.startsWith('-')) {
      negative = true;
      body = body.substring(1);
    } else if (body.startsWith('+')) {
      body = body.substring(1);
    }
    final dot = body.indexOf('.');
    var intPart = body;
    var fracPart = '';
    if (dot >= 0) {
      intPart = body.substring(0, dot);
      fracPart = body.substring(dot + 1);
    }
    if (intPart.isEmpty && fracPart.isEmpty) {
      throw FormatException("angka tidak valid '$s'");
    }
    if (!_digitsOnly(intPart) || !_digitsOnly(fracPart)) {
      throw FormatException("angka tidak valid '$s'");
    }
    final digits = intPart.isEmpty ? '0' : intPart;
    var u = BigInt.parse(digits + fracPart);
    if (negative) u = -u;
    return Dec._(u, fracPart.length);
  }

  factory Dec.fromInt(int v) => Dec._(BigInt.from(v), 0);

  factory Dec.fromBigInt(BigInt v) => Dec._(v, 0);

  static bool _digitsOnly(String s) {
    for (var i = 0; i < s.length; i++) {
      final c = s.codeUnitAt(i);
      if (c < 48 || c > 57) return false;
    }
    return true;
  }

  bool get isZero => unscaled == BigInt.zero;

  int get sign => unscaled.sign;

  BigInt _up(int s) => unscaled * _ten.pow(s - scale);

  Dec operator +(Dec o) {
    final s = scale > o.scale ? scale : o.scale;
    return Dec._(_up(s) + o._up(s), s);
  }

  Dec operator -(Dec o) {
    final s = scale > o.scale ? scale : o.scale;
    return Dec._(_up(s) - o._up(s), s);
  }

  Dec operator -() => Dec._(-unscaled, scale);

  Dec operator *(Dec o) => Dec._(unscaled * o.unscaled, scale + o.scale);

  Dec abs() => unscaled.isNegative ? Dec._(-unscaled, scale) : this;

  /// Geser titik desimal: nilai * 10^exp (eksak).
  Dec shift10(int exp) {
    if (exp >= 0) return Dec._(unscaled * _ten.pow(exp), scale);
    return Dec._(unscaled, scale - exp);
  }

  /// Sisa pembagian terpotong; tanda mengikuti dividen ini.
  Dec remainderOf(Dec o) {
    if (o.isZero) throw const FormatException('modulo dengan nol');
    final s = scale > o.scale ? scale : o.scale;
    return Dec._(_up(s).remainder(o._up(s)), s);
  }

  /// Akar kuadrat eksak ke [targetScale] via Newton BigInt (CALC-MAT-05).
  Dec sqrtAt(int targetScale) {
    if (targetScale < 0) {
      throw const FormatException('skala tidak boleh negatif');
    }
    if (sign < 0) {
      throw const FormatException('akar bilangan negatif');
    }
    if (isZero) return zero;
    var t = targetScale;
    while (2 * t < scale || (2 * t - scale).isOdd) {
      t++;
    }
    final n = unscaled * _ten.pow(2 * t - scale);
    return Dec._(_isqrt(n), t);
  }

  static BigInt _isqrt(BigInt n) {
    if (n < BigInt.two) return n;
    var x = BigInt.one << ((n.bitLength + 1) ~/ 2);
    while (true) {
      final y = (x + n ~/ x) >> 1;
      if (y >= x) return x;
      x = y;
    }
  }

  /// Konversi khusus jalur perkiraan (transendental): 15 digit
  /// signifikan dari double. JANGAN dipakai untuk nilai eksak -
  /// double sudah dibulatkan biner (CALC-MAT-01).
  static Dec fromApproxDouble(double v) {
    if (v.isNaN || v.isInfinite) {
      throw const FormatException('nilai tidak terdefinisi');
    }
    if (v == 0) return zero;
    final s = v.toStringAsExponential(14);
    final e = s.indexOf('e');
    final mant = Dec.parse(s.substring(0, e));
    final exp = int.parse(s.substring(e + 1));
    return mant.shift10(exp);
  }

  /// Pangkat bulat non-negatif via exponentiation by squaring (eksak).
  /// Batas pangkat/hasil digit dicek pemanggil (CalcLimits).
  Dec powInt(int exponent) {
    if (exponent < 0) {
      throw const FormatException('pangkat negatif butuh divide eksplisit');
    }
    var base = this;
    var result = one;
    var e = exponent;
    while (e > 0) {
      if (e.isOdd) result = result * base;
      base = base * base;
      e ~/= 2;
    }
    return result;
  }

  /// Pembagian eksplisit: hasil dibulatkan ke [scale] digit desimal
  /// memakai [mode] (algoritma CALC-MAT-02).
  Dec divide(Dec o, {required int scale, required RoundingMode mode}) {
    if (o.isZero) throw const FormatException('pembagian dengan nol');
    if (scale < 0) throw const FormatException('skala tidak boleh negatif');
    final n = unscaled * _ten.pow(scale + o.scale);
    final d = o.unscaled * _ten.pow(this.scale);
    final nAbs = n.abs();
    final dAbs = d.abs();
    final q = nAbs ~/ dAbs;
    final r = nAbs.remainder(dAbs);
    final resultSign = sign * o.sign;
    final adjusted = _adjustQuotient(
      q,
      r: r,
      dAbs: dAbs,
      resultSign: resultSign,
      mode: mode,
    );
    return Dec._(resultSign < 0 ? -adjusted : adjusted, scale);
  }

  /// Bulatkan ke [targetScale] digit desimal memakai [mode].
  Dec roundTo(int targetScale, RoundingMode mode) {
    if (targetScale < 0) {
      throw const FormatException('skala tidak boleh negatif');
    }
    if (targetScale >= scale) {
      return Dec._(unscaled * _ten.pow(targetScale - scale), targetScale);
    }
    final p = _ten.pow(scale - targetScale);
    final uAbs = unscaled.abs();
    final q = uAbs ~/ p;
    final r = uAbs.remainder(p);
    final adjusted = _adjustQuotient(
      q,
      r: r,
      dAbs: p,
      resultSign: sign,
      mode: mode,
    );
    return Dec._(sign < 0 ? -adjusted : adjusted, targetScale);
  }

  /// Naikkan magnitude hasil bila mode pembulatan menghendaki.
  static BigInt _adjustQuotient(
    BigInt q, {
    required BigInt r,
    required BigInt dAbs,
    required int resultSign,
    required RoundingMode mode,
  }) {
    if (r == BigInt.zero) return q;
    final cmp = (r + r).compareTo(dAbs);
    final up = switch (mode) {
      RoundingMode.halfEven => cmp > 0 || (cmp == 0 && q.isOdd),
      RoundingMode.halfUp => cmp >= 0,
      RoundingMode.down => false,
      RoundingMode.up => true,
      RoundingMode.floor => resultSign < 0,
      RoundingMode.ceiling => resultSign > 0,
    };
    return up ? q + BigInt.one : q;
  }

  /// Bentuk tanpa nol beruntun di belakang koma (untuk hashCode kanonik).
  Dec get normalized {
    var u = unscaled;
    var s = scale;
    while (s > 0 && u != BigInt.zero && u.remainder(_ten) == BigInt.zero) {
      u = u ~/ _ten;
      s--;
    }
    return Dec._(u, s);
  }

  @override
  int compareTo(Dec o) {
    final s = scale > o.scale ? scale : o.scale;
    return _up(s).compareTo(o._up(s));
  }

  @override
  bool operator ==(Object other) => other is Dec && compareTo(other) == 0;

  @override
  int get hashCode {
    final n = normalized;
    return Object.hash(n.unscaled, n.scale);
  }

  /// Bentuk desimal kanonik, mis. `1.50` -> `1.50`, `.5` -> `0.5`.
  @override
  String toString() {
    final neg = unscaled.isNegative;
    var digits = unscaled.abs().toString();
    if (scale == 0) return neg ? '-$digits' : digits;
    while (digits.length <= scale) {
      digits = '0$digits';
    }
    final cut = digits.length - scale;
    final text = '${digits.substring(0, cut)}.${digits.substring(cut)}';
    return neg ? '-$text' : text;
  }
}

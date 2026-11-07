import 'dart:math' as math;

/// Deterministic arithmetic evaluator used by the `calc` tool and the direct
/// `tiko calc` command (PRD §6, §10). No `eval`, no shell, bounded input/depth.
///
/// Grammar:
///   expr   := term (('+' | '-') term)*
///   term   := unary (('*' | '/' | '%') unary)*
///   unary  := ('+' | '-') unary | power
///   power  := primary ('^' unary)?          (right-associative)
///   primary:= number | '(' expr ')'
class SafeMath {
  static const maxLength = 256;
  static const maxDepth = 64;

  /// Evaluates [input] and returns the canonical text form (e.g. `6`, `2.5`).
  /// Throws [FormatException] with a user-readable message on invalid input.
  static String calculate(String input) => format(evaluate(input));

  static double evaluate(String input) {
    final s = input.replaceAll(RegExp(r'\s+'), '');
    if (s.isEmpty) throw const FormatException('ekspresi kosong');
    if (s.length > maxLength) {
      throw const FormatException('ekspresi terlalu panjang');
    }
    final p = _Parser(s);
    final v = p.parseExpr(0);
    if (p.i != s.length) {
      throw FormatException("karakter tak dikenal '${s[p.i]}' di posisi ${p.i + 1}");
    }
    if (v.isNaN || v.isInfinite) {
      throw const FormatException('hasil tidak terdefinisi');
    }
    return v;
  }

  /// `6.0` -> `6`, `2.5` -> `2.5`, `-0.0` -> `0`.
  static String format(double v) {
    if (v == 0) return '0';
    if (v == v.roundToDouble() && v.abs() < 1e15) return v.toInt().toString();
    return v.toString();
  }
}

class _Parser {
  _Parser(this.s);
  final String s;
  int i = 0;

  bool _at(String c) => i < s.length && s[i] == c;

  double parseExpr(int depth) {
    _guard(depth);
    var v = parseTerm(depth);
    while (_at('+') || _at('-')) {
      final op = s[i++];
      final r = parseTerm(depth);
      v = op == '+' ? v + r : v - r;
    }
    return v;
  }

  double parseTerm(int depth) {
    var v = parseUnary(depth);
    while (_at('*') || _at('/') || _at('%')) {
      final op = s[i++];
      final r = parseUnary(depth);
      switch (op) {
        case '*':
          v = v * r;
        case '/':
          if (r == 0) throw const FormatException('pembagian dengan nol');
          v = v / r;
        default:
          if (r == 0) throw const FormatException('modulo dengan nol');
          v = v % r;
      }
    }
    return v;
  }

  double parseUnary(int depth) {
    _guard(depth);
    if (_at('+')) {
      i++;
      return parseUnary(depth + 1);
    }
    if (_at('-')) {
      i++;
      return -parseUnary(depth + 1);
    }
    return parsePower(depth);
  }

  double parsePower(int depth) {
    final base = parsePrimary(depth);
    if (_at('^')) {
      i++;
      final exp = parseUnary(depth + 1);
      final r = math.pow(base, exp).toDouble();
      if (r.isNaN || r.isInfinite) {
        throw const FormatException('hasil pangkat tidak terdefinisi');
      }
      return r;
    }
    return base;
  }

  double parsePrimary(int depth) {
    _guard(depth);
    if (_at('(')) {
      i++;
      final v = parseExpr(depth + 1);
      if (!_at(')')) throw const FormatException('kurung tidak seimbang');
      i++;
      return v;
    }
    final start = i;
    var dots = 0;
    while (i < s.length) {
      final c = s.codeUnitAt(i);
      if (c >= 48 && c <= 57) {
        i++;
      } else if (c == 46) {
        dots++;
        i++;
      } else {
        break;
      }
    }
    if (start == i) {
      throw FormatException(
        i < s.length
            ? "angka diharapkan di posisi ${i + 1}, ditemukan '${s[i]}'"
            : 'ekspresi tidak lengkap',
      );
    }
    if (dots > 1) throw const FormatException('format angka tidak valid');
    final text = s.substring(start, i);
    final n = double.tryParse(text);
    if (n == null) throw FormatException("angka tidak valid '$text'");
    return n;
  }

  void _guard(int depth) {
    if (depth > SafeMath.maxDepth) {
      throw const FormatException('ekspresi terlalu dalam');
    }
  }
}

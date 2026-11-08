import '../core/errors.dart';
import '../core/limits.dart';
import '../core/numeric.dart';
import '../core/rounding.dart';
import '../parse/ast.dart';
import 'constants.dart';
import 'functions.dart';

/// Konteks evaluasi memuat parameter precision dan hasil samping
/// (warnings, approximate).
final class EvalContext {
  EvalContext({
    this.scale = 12,
    this.rounding = RoundingMode.halfEven,
    this.angleUnit = 'rad',
    this.limits = CalcLimits.defaults,
  }) : warnings = [], approximate = false;

  final int scale;
  final RoundingMode rounding;
  final String angleUnit; // 'rad' | 'deg'
  final CalcLimits limits;
  final List<String> warnings;
  bool approximate;
}

/// Visitor atas AST (CALC-MAT-05b). Semua operasi lewat Dec; tidak ada
/// eval. Galat selalu CalcException berkode dan berposisi.
final class Evaluator {
  const Evaluator();

  Dec eval(Node node, EvalContext ctx) {
    switch (node) {
      case NumNode(:final value):
        return value;
      case IdentNode(:final name, :final position):
        final c = MathConstants.byName[name];
        if (c == null) {
          throw CalcException(
            CalcErrorCodes.unknownSymbol,
            "Konstanta '$name' tidak dikenal",
            position: position,
            hint: 'fungsi harus dipanggil dengan kurung, mis. sqrt(2)',
          );
        }
        ctx.approximate = true;
        return Dec.parse(c);
      case UnaryNode(:final op, :final child):
        final v = eval(child, ctx);
        return op == '-' ? -v : v;
      case PercentNode(:final child):
        // Berdiri sendiri: persen = nilai/100.
        return eval(child, ctx)
            .divide(Dec.fromInt(100), scale: ctx.scale, mode: ctx.rounding);
      case FactorialNode(:final child, :final position):
        return _factorial(eval(child, ctx), position, ctx);
      case BinaryNode(:final op, :final left, :final right, :final position):
        return _binary(op, left, right, position, ctx);
      case CallNode(:final name, :final args, :final position):
        final fn = CalcFunctions.all[name];
        if (fn == null) {
          throw CalcException(
            CalcErrorCodes.unknownSymbol,
            "Fungsi '$name' tidak dikenal",
            position: position,
          );
        }
        final values = [for (final a in args) eval(a, ctx)];
        return fn(values, ctx);
    }
  }

  Dec _factorial(Dec v, int position, EvalContext ctx) {
    if (v.sign < 0) {
      throw CalcException(
        CalcErrorCodes.domain,
        'Faktorial bilangan negatif',
        position: position,
      );
    }
    if (v.scale != 0) {
      throw CalcException(
        CalcErrorCodes.domain,
        'Faktorial butuh bilangan bulat',
        position: position,
      );
    }
    if (v.unscaled > BigInt.from(ctx.limits.maxFactorial)) {
      throw CalcException(
        CalcErrorCodes.limit,
        'Faktorial melebihi batas (maksimum ${ctx.limits.maxFactorial})',
        position: position,
      );
    }
    return Dec.fromBigInt(CalcFunctions.factorial(v.unscaled.toInt(), ctx.limits));
  }

  Dec _binary(
    String op,
    Node left,
    Node right,
    int position,
    EvalContext ctx,
  ) {
    // Operand kanan berbentuk persen pada +/- memakai basis operand kiri
    // (gaya kalkulator saku, CALC-MAT-04b).
    if ((op == '+' || op == '-') && right is PercentNode) {
      final base = eval(left, ctx);
      final pct = eval(right.child, ctx)
          .divide(Dec.fromInt(100), scale: ctx.scale, mode: ctx.rounding);
      ctx.warnings.add('PERCENT_BASE_LEFT');
      return op == '+' ? base + base * pct : base - base * pct;
    }
    final a = eval(left, ctx);
    final b = eval(right, ctx);
    switch (op) {
      case '+':
        return a + b;
      case '-':
        return a - b;
      case '*':
        return a * b;
      case '/':
        return a.divide(b, scale: ctx.scale, mode: ctx.rounding);
      case 'mod':
        return a.remainderOf(b);
      case '^':
        return CalcFunctions.power(a, b, ctx);
    }
    throw CalcException(
      CalcErrorCodes.syntax,
      "Operator tidak dikenal '$op'",
      position: position,
    );
  }
}

import 'core/errors.dart';
import 'core/limits.dart';
import 'core/numeric.dart';
import 'core/result.dart';
import 'core/rounding.dart';
import 'eval/evaluator.dart';
import 'parse/locale_numbers.dart';
import 'parse/parser.dart';
import 'parse/rewrite_id.dart';
import 'parse/tokenizer.dart';

/// Mesin evaluasi tunggal (P7): kanonikalisasi Unicode -> penulisan
/// ulang frasa Indonesia -> locale -> token -> parse -> eval.
/// Dipakai bersama oleh tool LLM dan direct command tiko calc.
final class CalcEngine {
  const CalcEngine({this.limits = CalcLimits.defaults});

  final CalcLimits limits;

  CalcResult evaluate(
    String input, {
    int scale = 12,
    RoundingMode rounding = RoundingMode.halfEven,
    String angleUnit = 'rad',
    String locale = 'id',
    bool strict = false,
  }) {
    final sw = Stopwatch()..start();
    try {
      final trimmed = input.trim();
      if (trimmed.isEmpty) {
        throw const CalcException(
          CalcErrorCodes.syntax,
          'Ekspresi kosong',
        );
      }
      if (trimmed.length > limits.maxExpressionLength) {
        throw CalcException(
          CalcErrorCodes.limit,
          'Ekspresi terlalu panjang (maksimum '
              '${limits.maxExpressionLength} karakter)',
        );
      }
      final canonical = _canonicalizeUnicode(trimmed);
      final rewritten = RewriteId.rewrite(canonical) ?? canonical;
      final loc = LocaleNumbers.canonicalize(
        rewritten,
        locale: locale,
        strict: strict,
      );
      final ast = Parser(
        const Tokenizer().tokenize(loc.text),
        limits: limits,
      ).parse();
      final ctx = EvalContext(
        scale: scale,
        rounding: rounding,
        angleUnit: angleUnit,
        limits: limits,
      )..warnings.addAll(loc.warnings);
      final result = const Evaluator().eval(ast, ctx).normalized;
      return CalcResult(
        ok: true,
        value: result.toString(),
        display: _formatDisplay(result, scale, rounding, locale),
        normalizedExpr: loc.text,
        approximate: ctx.approximate,
        precision: {'scale': scale, 'rounding': rounding.wireName},
        warnings: List.unmodifiable(ctx.warnings),
        meta: {
          'algo': 'calc/1.0.0',
          'elapsed_ms': sw.elapsedMilliseconds,
        },
      );
    } on CalcException catch (e) {
      return _errorResult(e);
    } on FormatException catch (e) {
      return _fromFormatException(e);
    }
  }

  /// Kanonikalisasi simbol Unicode umum SEBELUM validasi (CWE-95).
  static String _canonicalizeUnicode(String input) {
    var s = input;
    s = s.replaceAll('×', '*'); // tanda kali
    s = s.replaceAll('÷', '/'); // tanda bagi
    s = s.replaceAll('−', '-'); // minus Unicode
    s = s.replaceAll(' ', ' '); // spasi tak-terputus
    s = s.replaceAll(' ', ' '); // spasi tipis
    return s;
  }

  /// Tampilan locale: id memakai ribuan titik dan desimal koma.
  static String _formatDisplay(
    Dec value,
    int scale,
    RoundingMode rounding,
    String locale,
  ) {
    var v = value;
    if (v.scale > scale) {
      v = v.roundTo(scale, rounding);
    }
    final text = v.normalized.toString();
    final decSep = locale == 'en' ? '.' : ',';
    final grpSep = locale == 'en' ? ',' : '.';
    final neg = text.startsWith('-');
    final body = neg ? text.substring(1) : text;
    final dot = body.indexOf('.');
    final intPart = dot < 0 ? body : body.substring(0, dot);
    final frac = dot < 0 ? '' : body.substring(dot + 1);
    final grouped = _group(intPart, grpSep);
    final sign = neg ? '-' : '';
    if (frac.isEmpty) return '$sign$grouped';
    return '$sign$grouped$decSep$frac';
  }

  static String _group(String digits, String sep) {
    final b = StringBuffer();
    for (var i = 0; i < digits.length; i++) {
      if (i > 0 && (digits.length - i) % 3 == 0) {
        b.write(sep);
      }
      b.write(digits[i]);
    }
    return b.toString();
  }

  static CalcResult _errorResult(CalcException e) => CalcResult(
        ok: false,
        approximate: false,
        error: e,
      );

  /// Galat internal bertipe FormatException dipetakan ke kode kontrak.
  static CalcResult _fromFormatException(FormatException e) {
    final m = e.message;
    final code = m.contains('pembagian dengan nol') ||
            m.contains('modulo dengan nol')
        ? CalcErrorCodes.divZero
        : m.contains('akar bilangan negatif')
            ? CalcErrorCodes.domain
            : CalcErrorCodes.syntax;
    return _errorResult(CalcException(code, m));
  }
}

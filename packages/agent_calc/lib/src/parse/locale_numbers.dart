import '../core/errors.dart';
import '../core/numeric.dart';

/// Hasil kanonikalisasi angka locale (CALC-MAT-06).
final class LocaleNumbersResult {
  const LocaleNumbersResult(this.text, this.warnings);
  final String text;
  final List<String> warnings;
}

/// Penguraian angka format Indonesia/Inggris (CALC-MAT-06):
/// pemisah ribuan, desimal koma, sufiks pengali (rb, juta, ...),
/// peringatan ambigu, dan notasi ilmiah.
final class LocaleNumbers {
  LocaleNumbers._();

  static final RegExp _suffix = RegExp(
    '(\\d[\\d.,]*)(\\s*)(ribu|rb|juta|jt|miliar|milyar|triliun|k)\\b',
    caseSensitive: false,
  );

  static final RegExp _numberToken =
      RegExp(r'\\d[\\d.,]*(?:[eE][+-]?\\d+)?');

  static const Map<String, int> _shifts = {
    'rb': 3, 'ribu': 3, 'k': 3,
    'jt': 6, 'juta': 6,
    'miliar': 9, 'milyar': 9,
    'triliun': 12,
  };

  /// Kanonikalisasi: sufiks pengali dulu, lalu pemisah desimal/ribuan.
  static LocaleNumbersResult canonicalize(
    String input, {
    String locale = 'id',
    bool strict = false,
  }) {
    var text = _applySuffixes(input, locale);
    return _applySeparators(text, locale, strict);
  }

  static String _applySuffixes(String input, String locale) {
    var out = input;
    for (var i = 0; i < 8; i++) {
      final m = _suffix.firstMatch(out);
      if (m == null) return out;
      final value = classify(m.group(1)!, locale: locale);
      final shifted =
          value.shift10(_shifts[m.group(3)!.toLowerCase()]!).normalized;
      out = out.substring(0, m.start) +
          shifted.toString() +
          out.substring(m.end);
    }
    return out;
  }

  static LocaleNumbersResult _applySeparators(
    String input,
    String locale,
    bool strict,
  ) {
    final warnings = <String>[];
    final text = input.replaceAllMapped(_numberToken, (m) {
      final tok = m.group(0)!;
      if (RegExp(r'^\\d[\\d.,]*[eE][+-]?\\d+$').hasMatch(tok)) {
        return tok; // notasi ilmiah: biarkan
      }
      return _convert(tok, locale, strict, warnings);
    });
    return LocaleNumbersResult(text, warnings);
  }

  /// Klasifikasi satu token angka menjadi Dec murni (CALC-MAT-06).
  static Dec classify(String token, {String locale = 'id'}) {
    final plain = token.trim();
    if (locale == 'en') {
      if (RegExp(r'^\\d{1,3}(,\\d{3})+(\\.\\d+)?$').hasMatch(plain)) {
        return Dec.parse(plain.replaceAll(',', ''));
      }
      if (RegExp(r'^\\d+,\\d+$').hasMatch(plain)) {
        return Dec.parse(plain.replaceFirst(',', '.'));
      }
      return Dec.parse(plain);
    }
    // locale id: ambigu dicek SEBELUM aturan grup ribuan.
    if (RegExp(r'^\\d+\\.\\d{3}$').hasMatch(plain)) {
      return Dec.parse(plain.replaceAll('.', ''));
    }
    if (RegExp(r'^\\d{1,3}(\\.\\d{3})+(,\\d+)?$').hasMatch(plain)) {
      return Dec.parse(
        plain.replaceAll('.', '').replaceFirst(',', '.'),
      );
    }
    if (RegExp(r'^\\d+,\\d+$').hasMatch(plain)) {
      return Dec.parse(plain.replaceFirst(',', '.'));
    }
    return Dec.parse(plain);
  }

  static String _convert(
    String token,
    String locale,
    bool strict,
    List<String> warnings,
  ) {
    final plain = token.trim();
    if (locale == 'en') {
      if (RegExp(r'^\\d{1,3}(,\\d{3})+(\\.\\d+)?$').hasMatch(plain)) {
        return plain.replaceAll(',', '');
      }
      if (RegExp(r'^\\d+,\\d+$').hasMatch(plain)) {
        warnings.add('W_DECIMAL_POINT');
        return plain.replaceFirst(',', '.');
      }
      return plain;
    }
    if (RegExp(r'^\\d+\\.\\d{3}$').hasMatch(plain)) {
      if (strict) {
        throw CalcException(
          CalcErrorCodes.ambiguousNumber,
          "Angka ambigu '$plain': tulus 1500 atau 1500.000",
          hint: 'tulis 1.500,00 atau 1500 bila maksudmu ribuan',
        );
      }
      warnings.add('W_AMBIGUOUS_NUMBER');
      return plain.replaceAll('.', '');
    }
    if (RegExp(r'^\\d{1,3}(\\.\\d{3})+(,\\d+)?$').hasMatch(plain)) {
      return plain.replaceAll('.', '').replaceFirst(',', '.');
    }
    if (RegExp(r'^\\d+,\\d+$').hasMatch(plain)) {
      return plain.replaceFirst(',', '.');
    }
    if (RegExp(r'^\\d+\\.\\d+$').hasMatch(plain)) {
      warnings.add('W_DECIMAL_POINT');
      return plain;
    }
    return plain;
  }
}

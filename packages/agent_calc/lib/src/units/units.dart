import '../core/errors.dart';
import '../core/numeric.dart';
import '../eval/evaluator.dart';

/// Konversi satuan (TASK-CALC-12): tabel faktor eksak per family
/// (panjang, massa, waktu, volume, luas, data, kecepatan) plus suhu
/// afine. Nama satuan diterima sebagai ident mentah lewat bentuk
/// khusus convert(nilai, dari, ke) pada evaluator. Satuan tidak
/// dikenal atau beda family memakai CALC_E_UNIT_MISMATCH.
final class CalcUnits {
  CalcUnits._();

  /// Nama satuan -> family (untuk cek kompatibilitas).
  static const Map<String, String> _family = {
    'mm': 'panjang', 'cm': 'panjang', 'm': 'panjang', 'km': 'panjang',
    'inci': 'panjang', 'in': 'panjang', 'kaki': 'panjang',
    'ft': 'panjang', 'yard': 'panjang', 'yd': 'panjang',
    'mil': 'panjang', 'mil_laut': 'panjang',
    'mg': 'massa', 'g': 'massa', 'kg': 'massa', 'kw': 'massa',
    'ons': 'massa', 'ton': 'massa', 'oz': 'massa', 'lb': 'massa',
    'detik': 'waktu', 's': 'waktu', 'menit': 'waktu', 'jam': 'waktu',
    'hari': 'waktu', 'minggu': 'waktu',
    'ml': 'volume', 'cc': 'volume', 'l': 'volume', 'liter': 'volume',
    'm3': 'volume', 'galon': 'volume', 'galon_uk': 'volume',
    'cm2': 'luas', 'm2': 'luas', 'km2': 'luas', 'ha': 'luas',
    'are': 'luas', 'ft2': 'luas',
    'b': 'data', 'byte': 'data', 'kb': 'data', 'mb': 'data',
    'gb': 'data', 'tb': 'data', 'kib': 'data', 'mib': 'data',
    'gib': 'data', 'tib': 'data',
    'km_per_jam': 'kecepatan', 'm_per_detik': 'kecepatan',
    'mph': 'kecepatan', 'knot': 'kecepatan',
  };

  /// Nama satuan -> faktor konversi eksak ke basis family.
  static final Map<String, Dec> _factor = {
    'mm': Dec.parse('0.001'),
    'cm': Dec.parse('0.01'),
    'm': Dec.one,
    'km': Dec.fromInt(1000),
    'inci': Dec.parse('0.0254'),
    'in': Dec.parse('0.0254'),
    'kaki': Dec.parse('0.3048'),
    'ft': Dec.parse('0.3048'),
    'yard': Dec.parse('0.9144'),
    'yd': Dec.parse('0.9144'),
    'mil': Dec.parse('1609.344'),
    'mil_laut': Dec.fromInt(1852),
    'mg': Dec.parse('0.000001'),
    'g': Dec.parse('0.001'),
    'kg': Dec.one,
    'kw': Dec.fromInt(100),
    'ons': Dec.parse('0.1'),
    'ton': Dec.fromInt(1000),
    'oz': Dec.parse('0.028349523125'),
    'lb': Dec.parse('0.45359237'),
    'detik': Dec.one,
    's': Dec.one,
    'menit': Dec.fromInt(60),
    'jam': Dec.fromInt(3600),
    'hari': Dec.fromInt(86400),
    'minggu': Dec.fromInt(604800),
    'ml': Dec.parse('0.001'),
    'cc': Dec.parse('0.001'),
    'l': Dec.one,
    'liter': Dec.one,
    'm3': Dec.fromInt(1000),
    'galon': Dec.parse('3.785411784'),
    'galon_uk': Dec.parse('4.54609'),
    'cm2': Dec.parse('0.0001'),
    'm2': Dec.one,
    'km2': Dec.fromInt(1000000),
    'ha': Dec.fromInt(10000),
    'are': Dec.fromInt(100),
    'ft2': Dec.parse('0.09290304'),
    'b': Dec.one,
    'byte': Dec.one,
    'kb': Dec.fromInt(1000),
    'mb': Dec.fromInt(1000000),
    'gb': Dec.fromInt(1000000000),
    'tb': Dec.fromInt(1000000000000),
    'kib': Dec.fromInt(1024),
    'mib': Dec.fromInt(1048576),
    'gib': Dec.fromInt(1073741824),
    'tib': Dec.fromInt(1099511627776),
    'km_per_jam': Dec.one,
    'm_per_detik': Dec.parse('3.6'),
    'mph': Dec.parse('1.609344'),
    'knot': Dec.parse('1.852'),
  };

  /// Konversi linear: nilai * faktor(dari) / faktor(ke).
  static Dec convert(Dec value, String fromRaw, String toRaw, EvalContext ctx) {
    final from = fromRaw.toLowerCase();
    final to = toRaw.toLowerCase();
    if (_isTemp(from) || _isTemp(to)) {
      return _convertTemp(value, from, to, fromRaw, toRaw, ctx);
    }
    final ff = _factor[from];
    final tf = _factor[to];
    if (ff == null || tf == null) {
      final unknown = ff == null && tf == null
          ? "'$fromRaw' dan '$toRaw'"
          : (ff == null ? "'$fromRaw'" : "'$toRaw'");
      throw CalcException(
        CalcErrorCodes.unitMismatch,
        'Satuan tidak dikenal: $unknown',
        hint: 'contoh: convert(5, km, m)',
      );
    }
    final fromFamily = _family[from]!;
    final toFamily = _family[to]!;
    if (fromFamily != toFamily) {
      throw CalcException(
        CalcErrorCodes.unitMismatch,
        "Satuan '$fromRaw' ($fromFamily) tidak kompatibel dengan "
        "'$toRaw' ($toFamily)",
      );
    }
    return (value * ff).divide(tf, scale: ctx.scale, mode: ctx.rounding);
  }

  /// Suhu: transformasi afine, pivot celcius.
  static Dec _convertTemp(
    Dec value,
    String from,
    String to,
    String fromRaw,
    String toRaw,
    EvalContext ctx,
  ) {
    final f = _isTemp(from);
    final t = _isTemp(to);
    if (!f || !t) {
      final bad = f ? toRaw : fromRaw;
      throw CalcException(
        CalcErrorCodes.unitMismatch,
        "Satuan suhu tidak dikenal: '$bad'",
        hint: 'satuan suhu: c, f, atau k',
      );
    }
    final c = _toCelsius(value, from, ctx);
    return _fromCelsius(c, to, ctx);
  }

  static bool _isTemp(String u) =>
      u == 'c' || u == 'celcius' || u == 'celsius' || u == 'f' ||
      u == 'fahrenheit' || u == 'k' || u == 'kelvin';

  static Dec _toCelsius(Dec v, String unit, EvalContext ctx) {
    switch (unit) {
      case 'f':
      case 'fahrenheit':
        return ((v - Dec.fromInt(32)) * Dec.fromInt(5))
            .divide(Dec.fromInt(9), scale: ctx.scale, mode: ctx.rounding);
      case 'k':
      case 'kelvin':
        return v - Dec.parse('273.15');
    }
    return v;
  }

  static Dec _fromCelsius(Dec c, String unit, EvalContext ctx) {
    switch (unit) {
      case 'f':
      case 'fahrenheit':
        return (c * Dec.fromInt(9))
                .divide(
                  Dec.fromInt(5),
                  scale: ctx.scale,
                  mode: ctx.rounding,
                ) +
            Dec.fromInt(32);
      case 'k':
      case 'kelvin':
        return c + Dec.parse('273.15');
    }
    return c;
  }
}

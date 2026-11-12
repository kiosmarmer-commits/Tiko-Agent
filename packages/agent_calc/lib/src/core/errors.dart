/// Galat berkode dan berposisi; tool tidak pernah mengembalikan angka
/// tebakan (CALC-ARC-05 P5). Kode galat stabil sebagai kontrak publik.
final class CalcException implements Exception {
  const CalcException(this.code, this.message, {this.position, this.hint});

  /// Kode galat stabil, mis. `CALC_E_SYNTAX` (lihat [CalcErrorCodes]).
  final String code;

  /// Pesan galat dalam bahasa Indonesia untuk pengguna akhir.
  final String message;

  /// Posisi karakter (0-based) bila relevan, mis. galat sintaks.
  final int? position;

  /// Saran perbaikan singkat.
  final String? hint;

  @override
  String toString() {
    final pos = position == null ? '' : ' (posisi $position)';
    final h = hint == null ? '' : ' - $hint';
    return '$code: $message$pos$h';
  }
}

/// Kode galat stabil sebagai kontrak (CALC-ARC-05).
abstract final class CalcErrorCodes {
  static const syntax = 'CALC_E_SYNTAX';
  static const unknownSymbol = 'CALC_E_UNKNOWN_SYMBOL';
  static const divZero = 'CALC_E_DIV_ZERO';
  static const domain = 'CALC_E_DOMAIN';
  static const limit = 'CALC_E_LIMIT';
  static const timeout = 'CALC_E_TIMEOUT';
  static const unitMismatch = 'CALC_E_UNIT_MISMATCH';
  static const noConvergence = 'CALC_E_NO_CONVERGENCE';
  static const ambiguousNumber = 'CALC_E_AMBIGUOUS_NUMBER';
  static const dataUnavailable = 'CALC_E_DATA_UNAVAILABLE';
  static const rateLimited = 'CALC_E_RATE_LIMITED';
  static const staleData = 'CALC_E_STALE_DATA';
}

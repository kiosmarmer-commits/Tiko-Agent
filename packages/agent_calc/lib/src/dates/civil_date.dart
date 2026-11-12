import '../core/errors.dart';
import '../core/numeric.dart';

/// Kalender sipil proleptik (TASK-CALC-18..20): tanpa zona waktu dan
/// DST, murni aritmetika integer. Tanggal direpresentasikan sebagai
/// bilangan YYYYMMDD. Algoritma days_from_civil / civil_from_days
/// (Hinnant), epoch 1970-01-01.
final class CivilDate {
  CivilDate._();

  static bool isLeap(int y) =>
      y % 4 == 0 && (y % 100 != 0 || y % 400 == 0);

  static int daysInMonth(int y, int m) {
    switch (m) {
      case 1:
      case 3:
      case 5:
      case 7:
      case 8:
      case 10:
      case 12:
        return 31;
      case 4:
      case 6:
      case 9:
      case 11:
        return 30;
      case 2:
        return isLeap(y) ? 29 : 28;
    }
    throw const CalcException(
      CalcErrorCodes.domain,
      'Bulan harus 1..12',
    );
  }

  /// Validasi YYYYMMDD; mengembalikan (y, m, d).
  static (int, int, int) parseYmd(Dec d) {
    if (d.scale != 0 || d.sign <= 0) {
      throw const CalcException(
        CalcErrorCodes.domain,
        'Tanggal harus YYYYMMDD, mis. 20260131',
      );
    }
    final v = d.unscaled;
    if (v > BigInt.from(99991231)) {
      throw const CalcException(
        CalcErrorCodes.domain,
        'Tahun harus 1..9999',
      );
    }
    final y = (v ~/ BigInt.from(10000)).toInt();
    final m = ((v ~/ BigInt.from(100)) % BigInt.from(100)).toInt();
    final day = (v % BigInt.from(100)).toInt();
    if (m < 1 || m > 12) {
      throw const CalcException(
        CalcErrorCodes.domain,
        'Bulan tidak valid',
      );
    }
    if (day < 1 || day > daysInMonth(y, m)) {
      throw const CalcException(
        CalcErrorCodes.domain,
        'Tanggal tidak valid',
      );
    }
    return (y, m, day);
  }

  /// Hari sejak epoch 1970-01-01 (boleh negatif).
  static int daysFromCivil(int y, int m, int d) {
    final yy = m <= 2 ? y - 1 : y;
    final era = (yy >= 0 ? yy : yy - 399) ~/ 400;
    final yoe = yy - era * 400;
    final doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) ~/ 5 + d - 1;
    final doe = yoe * 365 + yoe ~/ 4 - yoe ~/ 100 + doy;
    return era * 146097 + doe - 719468;
  }

  /// Inverse [daysFromCivil].
  static (int, int, int) civilFromDays(int z) {
    final zz = z + 719468;
    final era = (zz >= 0 ? zz : zz - 146096) ~/ 146097;
    final doe = zz - era * 146097;
    final yoe =
        (doe - doe ~/ 1460 + doe ~/ 36524 - doe ~/ 146096) ~/ 365;
    final y0 = yoe + era * 400;
    final doy = doe - (365 * yoe + yoe ~/ 4 - yoe ~/ 100);
    final mp = (5 * doy + 2) ~/ 153;
    final d = doy - (153 * mp + 2) ~/ 5 + 1;
    final m = mp + (mp < 10 ? 3 : -9);
    return (m <= 2 ? y0 + 1 : y0, m, d);
  }

  static int _toYmd(int y, int m, int d) => y * 10000 + m * 100 + d;

  /// Selisih hari b - a.
  static int diff((int, int, int) a, (int, int, int) b) {
    return daysFromCivil(b.$1, b.$2, b.$3) -
        daysFromCivil(a.$1, a.$2, a.$3);
  }

  /// Tambah hari kalender.
  static int addDays((int, int, int) ymd, int days) {
    if (days.abs() > 4000000) {
      throw const CalcException(
        CalcErrorCodes.limit,
        'Penambahan hari terlalu besar',
      );
    }
    final z = daysFromCivil(ymd.$1, ymd.$2, ymd.$3) + days;
    final (y, m, d) = civilFromDays(z);
    _checkRange(y);
    return _toYmd(y, m, d);
  }

  /// Tambah bulan kalender; hari di-clamp ke akhir bulan target.
  static int addMonths((int, int, int) ymd, int months) {
    if (months.abs() > 120000) {
      throw const CalcException(
        CalcErrorCodes.limit,
        'Penambahan bulan terlalu besar',
      );
    }
    final total = ymd.$1 * 12 + (ymd.$2 - 1) + months;
    final y = total ~/ 12;
    final m = (total % 12 + 12) % 12 + 1;
    _checkRange(y);
    final dim = daysInMonth(y, m);
    return _toYmd(y, m, ymd.$3 < dim ? ymd.$3 : dim);
  }

  /// Hari dalam minggu ISO: 1 = Senin .. 7 = Minggu.
  static int dayOfWeek((int, int, int) ymd) {
    final z = daysFromCivil(ymd.$1, ymd.$2, ymd.$3);
    return ((z + 3) % 7 + 7) % 7 + 1;
  }

  static void _checkRange(int y) {
    if (y < 1 || y > 9999) {
      throw const CalcException(
        CalcErrorCodes.domain,
        'Hasil tanggal di luar rentang tahun 1..9999',
      );
    }
  }
}

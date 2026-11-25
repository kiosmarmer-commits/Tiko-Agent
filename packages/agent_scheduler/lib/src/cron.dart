import 'timezones.dart';

/// Strict 5-field cron parser/matcher (minute hour dom month dow).
/// Supports *, N, N-M, */N, N-M/S and comma-separated combinations.
class CronExpression {
  CronExpression._(
    this.minutes, this.hours, this.doms, this.months, this.dows, {
    required this.domRestricted,
    required this.dowRestricted,
  });

  final Set<int> minutes;
  final Set<int> hours;
  final Set<int> doms;
  final Set<int> months;
  final Set<int> dows; // 0=Sun .. 6=Sat
  final bool domRestricted;
  final bool dowRestricted;

  factory CronExpression.parse(String expr) {
    final parts = expr.trim().split(RegExp(r'\s+'));
    if (parts.length != 5 || parts.any((part) => part.isEmpty)) {
      throw FormatException('cron harus 5 field: "$expr"');
    }
    final doms = _field(parts[2], 1, 31);
    final months = _field(parts[3], 1, 12);
    final dows = _field(parts[4], 0, 6);
    // A day-of-month schedule that cannot exist in any allowed month
    // would never fire; reject it at parse time, unless the day-of-week
    // field is also restricted and can still match via OR semantics.
    if (!_isWildcard(parts[2]) &&
        _isWildcard(parts[4]) &&
        !_domPossible(doms, months)) {
      throw FormatException(
        'kombinasi hari-bulan tidak mungkin terjadi: "$expr"',
      );
    }
    return CronExpression._(
      _field(parts[0], 0, 59),
      _field(parts[1], 0, 23),
      doms,
      months,
      dows,
      domRestricted: !_isWildcard(parts[2]),
      dowRestricted: !_isWildcard(parts[4]),
    );
  }

  static bool _isWildcard(String field) => field == '*' || field == '*/1';

  static const List<int> _daysInMonth = [
    31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31,
  ];

  /// True when at least one allowed day exists in an allowed month.
  /// February is treated as having 29 days because leap years recur
  /// within the scan horizon of [nextAfter].
  static bool _domPossible(Set<int> doms, Set<int> months) {
    for (final month in months) {
      final limit = _daysInMonth[month - 1];
      for (final day in doms) {
        if (day <= limit) return true;
      }
    }
    return false;
  }

  static Set<int> _field(String field, int min, int max) {
    final out = <int>{};
    for (final rawPart in field.split(',')) {
      final part = rawPart.trim();
      if (part.isEmpty) throw const FormatException('cron field kosong');
      final stepParts = part.split('/');
      if (stepParts.length > 2) throw FormatException('step cron invalid: $part');
      final step = stepParts.length == 2 ? int.tryParse(stepParts[1]) : 1;
      if (step == null || step < 1 || step > (max - min + 1)) {
        throw FormatException('step cron di luar batas: $part');
      }
      final base = stepParts.first;
      int start;
      int end;
      if (base == '*') {
        start = min;
        end = max;
      } else if (base.contains('-')) {
        final range = base.split('-');
        if (range.length != 2) throw FormatException('range cron invalid: $part');
        start = int.tryParse(range[0]) ?? -1;
        end = int.tryParse(range[1]) ?? -1;
      } else {
        if (stepParts.length == 2) {
          throw FormatException('step hanya boleh dipakai pada * atau range: $part');
        }
        start = int.tryParse(base) ?? -1;
        end = start;
      }
      if (start < min || end > max || start > end) {
        throw FormatException('nilai cron $part harus berada pada $min..$max');
      }
      for (var value = start; value <= end; value += step) {
        out.add(value);
      }
    }
    if (out.isEmpty) throw const FormatException('cron field tidak menghasilkan nilai');
    return out;
  }

  bool matches(DateTime dt) {
    if (!minutes.contains(dt.minute) ||
        !hours.contains(dt.hour) ||
        !months.contains(dt.month)) {
      return false;
    }
    final domMatch = doms.contains(dt.day);
    final dowMatch = dows.contains(dt.weekday % 7);
    // POSIX cron uses OR when both day fields are restricted; if only one is
    // restricted, only that field participates in the date match.
    if (domRestricted && dowRestricted) return domMatch || dowMatch;
    if (domRestricted) return domMatch;
    if (dowRestricted) return dowMatch;
    return true;
  }

  /// Cocokkan sebuah instant absolut terhadap jam dinding zona IANA
  /// [timezone]. Semua zona IANA didukung, termasuk zona dengan transisi
  /// DST; zona tak dikenal ditolak keras (fail-closed) agar job tidak
  /// pernah diam-diam dievaluasi di zona host.
  bool matchesAt(DateTime instant, {String timezone = 'UTC'}) =>
      matches(Tz.wallFromUtc(instant, timezone));

  /// [from] is an absolute instant; the returned instant is UTC.
  ///
  /// Kandidat dihitung pada jam dinding zona lalu dikonversi per kandidat,
  /// sehingga pergeseran offset DST diperhitungkan. Jam dinding ambigu
  /// (fold) memilih kemunculan pertama dan jam dinding yang tidak ada (gap)
  /// dinormalisasi maju oleh resolver zona — keduanya deterministik: setiap
  /// kemunculan jam dinding dijadwalkan tepat satu kali.
  DateTime nextAfter(
    DateTime from, {
    int maxScanMinutes = 60 * 24 * 366 * 8,
    String timezone = 'UTC',
  }) {
    final fromUtc = from.toUtc();
    final deadline = fromUtc.add(Duration(minutes: maxScanMinutes));
    final wallStart = Tz.wallFromUtc(fromUtc, timezone);
    final firstDay = DateTime.utc(wallStart.year, wallStart.month, wallStart.day);
    final maxDays = maxScanMinutes ~/ 1440 + 1;
    final sortedHours = hours.toList()..sort();
    final sortedMinutes = minutes.toList()..sort();

    // Scan dates, not every minute. This keeps rare annual schedules such as
    // 29 February efficient while still finding a valid occurrence up to the
    // configured horizon.
    for (var dayOffset = 0; dayOffset <= maxDays; dayOffset++) {
      final day = firstDay.add(Duration(days: dayOffset));
      if (!months.contains(day.month)) continue;
      final domMatch = doms.contains(day.day);
      final dowMatch = dows.contains(day.weekday % 7);
      final dateMatches = domRestricted && dowRestricted
          ? domMatch || dowMatch
          : domRestricted
              ? domMatch
              : dowRestricted
                  ? dowMatch
                  : true;
      if (!dateMatches) continue;

      for (final hour in sortedHours) {
        for (final minute in sortedMinutes) {
          final wall =
              DateTime.utc(day.year, day.month, day.day, hour, minute);
          if (!wall.isAfter(wallStart)) continue;
          final instant = Tz.utcFromWall(wall, timezone);
          if (instant.isAfter(fromUtc) && !instant.isAfter(deadline)) {
            return instant;
          }
        }
      }
    }
    throw StateError('no next cron match within scan window');
  }

}

/// Gap docs/13 c§1: frasa jadwal natural -> ekspresi cron 5 field ketat.
///
/// Input yang sudah 5 field dikembalikan apa adanya (setelah trim) dan akan
/// divalidasi [CronExpression.parse] oleh pemanggil (fail-closed). Frasa
/// yang didukung (case-insensitive, alias Indonesia):
/// - `every N menit|minute|min` -> `*/N * * * *` (N=1 -> `* * * * *`)
/// - `every N jam|hour|h`       -> `0 */N * * *` (N=1 -> `0 * * * *`)
/// - `every N hari|day`         -> `0 0 */N * *`
/// - `every N minggu|week`      -> `0 0 * * 1`
/// - `hourly` / `tiap jam`      -> `0 * * * *`
/// - `daily|harian [at|pukul] HH:MM` -> `M H * * *`
/// - `weekly|mingguan [dow] [at|pukul] HH:MM` -> `M H * * D`
///   (dow: mon/senin..sun/minggu, default senin)
/// - `monthly|bulanan <1-28> [at|pukul] HH:MM` -> `M H D * *`
///
/// Lempar [FormatException] untuk frasa yang dicoba tapi tidak cocok pola —
/// salah ketik tidak boleh diam-diam jadi `* * * * *`.
String normalizeCronInput(String input) {
  final raw = input.trim();
  final lower = raw.toLowerCase();
  final timeRe = RegExp(r'^([01]?\d|2[0-3]):([0-5]\d)$');
  String? parseTime(String token) {
    final m = timeRe.firstMatch(token);
    if (m == null) return null;
    final hour = int.parse(m.group(1)!);
    final minute = int.parse(m.group(2)!);
    return '$hour:${minute.toString().padLeft(2, '0')}';
  }

  List<String> splitTime(List<String> tokens) {
    final stripped = <String>[];
    String? time;
    for (final t in tokens) {
      final maybe = parseTime(t);
      if (maybe != null && time == null) {
        time = maybe;
        continue;
      }
      stripped.add(t);
    }
    return stripped + [if (time != null) time];
  }

  if (lower == 'hourly' || lower == 'tiap jam') return '0 * * * *';

  final words = lower
      .replaceAll(RegExp(r'[^a-z0-9:]+'), ' ')
      .replaceAllMapped(RegExp(r'(\d)([a-z])'), (m) => '${m[1]} ${m[2]}')
      .replaceAllMapped(RegExp(r'([a-z])(\d)'), (m) => '${m[1]} ${m[2]}')
      .trim()
      .split(RegExp(r' +'));

  if (words.isNotEmpty && (words.first == 'every' || words.first == 'tiap')) {
    final rest = words.sublist(1);
    var count = 1;
    if (rest.isNotEmpty && int.tryParse(rest.first) != null) {
      count = int.parse(rest.first);
      rest.removeAt(0);
    }
    if (count < 1 || count > 1440) {
      throw FormatException('cron natural: jumlah harus 1..1440: "$input"');
    }
    final unit = rest.isNotEmpty ? rest.first : '';
    switch (unit) {
      case 'menit':
      case 'minute':
      case 'minutes':
      case 'mins':
      case 'min':
      case 'm':
        return count == 1 ? '* * * * *' : '*/$count * * * *';
      case 'jam':
      case 'hour':
      case 'hours':
      case 'h':
        return count == 1 ? '0 * * * *' : '0 */$count * * *';
      case 'hari':
      case 'day':
      case 'days':
      case 'd':
        return '0 0 */$count * *';
      case 'minggu':
      case 'week':
      case 'weeks':
      case 'w':
        return '0 0 * * 1';
      default:
        throw FormatException(
          'cron natural: unit tidak dikenal "$unit" (min/jam/hari/minggu)',
        );
    }
  }

  final lead = words.isNotEmpty ? words.first : '';
  if (lead == 'daily' || lead == 'harian') {
    final time = _timeAfter(words.sublist(1), parseTime, input);
    return '${time[1]} ${time[0]} * * *';
  }
  if (lead == 'weekly' || lead == 'mingguan') {
    const dows = {
      'mon': 1, 'monday': 1, 'senin': 1, 'senen': 1,
      'tue': 2, 'tues': 2, 'tuesday': 2, 'selasa': 2,
      'wed': 3, 'weds': 3, 'wednesday': 3, 'rabu': 3,
      'thu': 4, 'thur': 4, 'thurs': 4, 'thursday': 4, 'kamis': 4,
      'fri': 5, 'friday': 5, 'jumat': 5, 'jumad': 5,
      'sat': 6, 'saturday': 6, 'sabtu': 6,
      'sun': 0, 'sunday': 0, 'minggu': 0, 'ahad': 0,
    };
    final rest = splitTime(words.sublist(1));
    var dow = 1;
    if (rest.isNotEmpty && dows.containsKey(rest.first)) {
      dow = dows[rest.first]!;
      rest.removeAt(0);
    }
    final time = _timeAfter(rest, parseTime, input);
    return '${time[1]} ${time[0]} * * $dow';
  }
  if (lead == 'monthly' || lead == 'bulanan') {
    final rest = splitTime(words.sublist(1));
    var dom = 1;
    if (rest.isNotEmpty &&
        int.tryParse(rest.first) != null &&
        int.parse(rest.first) >= 1 &&
        int.parse(rest.first) <= 28) {
      dom = int.parse(rest.first);
      rest.removeAt(0);
    }
    final time = _timeAfter(rest, parseTime, input);
    return '${time[1]} ${time[0]} $dom * *';
  }

  return raw;
}

/// Wajib HH:MM setelah secara opsional "at"/"pukul"; fail-closed bila tidak ada.
List<String> _timeAfter(
  List<String> tokens,
  String? Function(String) parseTime,
  String input,
) {
  String? time;
  for (final t in tokens) {
    final maybe = parseTime(t);
    if (maybe != null) {
      time = maybe;
      break;
    }
  }
  if (time == null) {
    throw FormatException(
        'cron natural: butuh waktu HH:MM (mis. "daily 08:30"): "$input"');
  }
  final parts = time.split(':');
  return ['${int.parse(parts[0])}', '${int.parse(parts[1])}']; // [jam, menit]
}

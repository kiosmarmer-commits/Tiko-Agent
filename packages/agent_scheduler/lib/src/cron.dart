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
    return CronExpression._(
      _field(parts[0], 0, 59),
      _field(parts[1], 0, 23),
      _field(parts[2], 1, 31),
      _field(parts[3], 1, 12),
      _field(parts[4], 0, 6),
      domRestricted: !_isWildcard(parts[2]),
      dowRestricted: !_isWildcard(parts[4]),
    );
  }

  static bool _isWildcard(String field) => field == '*' || field == '*/1';

  static Set<int> _field(String field, int min, int max) {
    final out = <int>{};
    for (final rawPart in field.split(',')) {
      final part = rawPart.trim();
      if (part.isEmpty) throw FormatException('cron field kosong');
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
    if (out.isEmpty) throw FormatException('cron field tidak menghasilkan nilai');
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

  /// Match an absolute UTC instant against the requested fixed-offset zone.
  /// IANA zones with daylight-saving transitions are rejected rather than
  /// silently evaluated in the host's timezone.
  bool matchesAt(DateTime instant, {String timezone = 'UTC'}) =>
      matches(_toWallTime(instant, timezone));

  /// [from] is an absolute instant; the returned instant is UTC.
  DateTime nextAfter(
    DateTime from, {
    int maxScanMinutes = 60 * 24 * 366 * 8,
    String timezone = 'UTC',
  }) {
    final offset = _offsetFor(timezone);
    final wallStart = from.toUtc().add(offset);
    final firstDay = DateTime.utc(wallStart.year, wallStart.month, wallStart.day);
    final deadline = wallStart.add(Duration(minutes: maxScanMinutes));
    final maxDays = deadline.difference(firstDay).inDays;
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
          final candidate = DateTime.utc(day.year, day.month, day.day, hour, minute);
          if (candidate.isAfter(wallStart) && !candidate.isAfter(deadline)) {
            return candidate.subtract(offset);
          }
        }
      }
    }
    throw StateError('no next cron match within scan window');
  }

  static DateTime _toWallTime(DateTime instant, String timezone) =>
      instant.toUtc().add(_offsetFor(timezone));

  static Duration _offsetFor(String timezone) {
    const offsets = <String, int>{
      'UTC': 0,
      'Etc/UTC': 0,
      'Asia/Jakarta': 7,
      'Asia/Pontianak': 7,
      'Asia/Makassar': 8,
      'Asia/Jayapura': 9,
    };
    final hours = offsets[timezone];
    if (hours == null) {
      throw FormatException(
        'timezone "$timezone" belum didukung; gunakan UTC atau zona Indonesia fixed-offset yang didukung',
      );
    }
    return Duration(hours: hours);
  }
}

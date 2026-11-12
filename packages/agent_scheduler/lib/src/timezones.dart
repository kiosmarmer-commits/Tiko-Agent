import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

/// Resolver zona IANA fail-closed untuk scheduler (perbaikan blocker:
/// "Full IANA timezone/DST support").
///
/// Memakai database zona IANA yang dibundel package:timezone
/// (data 2025c), sehingga seluruh nama zona IANA sah — termasuk zona
/// dengan transisi DST. Zona tak dikenal tetap ditolak keras
/// (FormatException), bukan diam-diam dievaluasi di zona host.
///
/// Konvensi transisi yang deterministik: jam dinding ambigu (fold, jam
/// mundur) memilih kemunculan pertama; jam dinding yang tidak ada (gap,
/// jam maju) dinormalisasi maju oleh resolver.
final class Tz {
  Tz._();

  static bool _ready = false;

  /// Resolve + validasi nama zona; melempar [FormatException] bila kosong,
  /// terlalu panjang, atau tidak ada di database IANA.
  static tz.Location resolve(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty || trimmed.length > 64) {
      throw FormatException('timezone tidak valid: "$name"');
    }
    if (!_ready) {
      tzdata.initializeTimeZones();
      _ready = true;
    }
    try {
      return tz.getLocation(trimmed);
    } catch (_) {
      throw FormatException('timezone IANA tidak dikenal: "$trimmed"');
    }
  }

  /// Jam dinding (naive UTC) dari sebuah instant absolut di zona [timezone].
  static DateTime wallFromUtc(DateTime instant, String timezone) {
    final wall = tz.TZDateTime.from(instant.toUtc(), resolve(timezone));
    return DateTime.utc(
      wall.year,
      wall.month,
      wall.day,
      wall.hour,
      wall.minute,
      wall.second,
    );
  }

  /// Instant absolut (UTC) dari jam dinding [wall] di zona [timezone].
  /// Fold memilih kemunculan pertama; gap dinormalisasi maju.
  static DateTime utcFromWall(DateTime wall, String timezone) {
    final instant = tz.TZDateTime(
      resolve(timezone),
      wall.year,
      wall.month,
      wall.day,
      wall.hour,
      wall.minute,
    );
    return DateTime.fromMillisecondsSinceEpoch(
      instant.millisecondsSinceEpoch,
      isUtc: true,
    );
  }
}

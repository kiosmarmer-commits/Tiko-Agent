// Fase F5 (docs/15 §6) — probe watcher + konteks antar-job. Model data
// murni di package scheduler; eksekusi probe HTTP milik runtime host.
import 'dart:convert';

/// Probe periodik job watcher. Hanya `url` (GET read-only): turn agen hanya
/// dipicu bila fingerprint status berubah (fail-closed terhadap jenis lain).
class WatchProbe {
  WatchProbe.url(String raw) : kind = kindUrl, url = _validated(raw);

  static const kindUrl = 'url';

  final String kind;
  final String url;

  static String _validated(String raw) {
    final url = raw.trim();
    if (url.isEmpty || url.length > 500) {
      throw const FormatException('watch url harus 1..500 karakter');
    }
    final parsed = Uri.tryParse(url);
    if (parsed == null ||
        !parsed.hasScheme ||
        (parsed.scheme != 'http' && parsed.scheme != 'https') ||
        parsed.userInfo.isNotEmpty) {
      throw const FormatException('watch url wajib http(s) tanpa kredensial');
    }
    return url;
  }

  static WatchProbe fromJson(Map<String, dynamic> m) {
    final kind = m['kind']?.toString();
    if (kind == kindUrl) {
      final url = m['url']?.toString() ?? '';
      return WatchProbe.url(url);
    }
    throw FormatException('invalid watch probe kind: $kind');
  }

  static WatchProbe? tryFromJson(Object? raw) {
    if (raw == null) return null;
    if (raw is! Map) throw const FormatException('invalid watch probe');
    return fromJson(Map<String, dynamic>.from(raw));
  }

  Map<String, dynamic> toJson() => {'kind': kind, 'url': url};
}

/// Fingerprint keadaan probe — dipersankan laporan perubahan status:
/// hanya bila string ini berubah turn agen watcher baru dipicu.
class WatchProbeResult {
  const WatchProbeResult({
    required this.fingerprint,
    required this.ok,
    this.detail = '',
    this.error,
  });

  final String fingerprint;
  final bool ok;
  final String detail;
  final String? error;
}

/// Checksum FNV-1a 32-bit standar (pure Dart, tanpa dependensi baru) untuk
/// fingerprint body probe — per-byte UTF-8, paritas dengan referensi.
String fnv1aHex(String input) {
  var hash = 0x811c9dc5;
  for (final byte in utf8.encode(input)) {
    hash ^= byte;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return hash.toRadixString(16).padLeft(8, '0');
}

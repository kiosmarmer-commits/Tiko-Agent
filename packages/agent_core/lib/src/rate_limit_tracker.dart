/// Rate limit tracking (Hermes `agent/rate_limit_tracker.py`): parse header
/// `x-ratelimit-{limit,remaining,reset}-{requests,tokens}[-1h]` (format Nous
/// Portal, juga dipakai OpenRouter / API OpenAI-compatible) dan simpan state
/// per provider untuk ditampilkan di perintah usage.
library;

/// Satu jendela rate-limit (mis. request per menit).
class RateLimitBucket {
  RateLimitBucket({
    this.limit = 0,
    this.remaining = 0,
    this.resetSeconds = 0,
    this.capturedAt = 0,
  });

  final int limit;
  final int remaining;
  final double resetSeconds;
  final double capturedAt; // epoch detik saat header ditangkap

  int get used => limit > 0 ? (limit - remaining).clamp(0, limit) : 0;

  double get usagePct =>
      limit > 0 ? (used / limit) * 100.0 : 0.0;

  /// Estimasi detik sampai reset, dikoreksi waktu berjalan sejak tangkap.
  double remainingSecondsNow({required double Function() clock}) =>
      (resetSeconds - (clock() - capturedAt)).clamp(0.0, double.infinity);
}

/// State rate-limit penuh dari header respons satu provider.
class RateLimitState {
  RateLimitState({
    RateLimitBucket? requestsMin,
    RateLimitBucket? requestsHour,
    RateLimitBucket? tokensMin,
    RateLimitBucket? tokensHour,
    this.capturedAt = 0,
    this.provider = '',
  })  : requestsMin = requestsMin ?? RateLimitBucket(),
        requestsHour = requestsHour ?? RateLimitBucket(),
        tokensMin = tokensMin ?? RateLimitBucket(),
        tokensHour = tokensHour ?? RateLimitBucket();

  final RateLimitBucket requestsMin;
  final RateLimitBucket requestsHour;
  final RateLimitBucket tokensMin;
  final RateLimitBucket tokensHour;
  final double capturedAt;
  final String provider;

  bool get hasData => capturedAt > 0;

  double ageSeconds({required double Function() clock}) =>
      hasData ? clock() - capturedAt : double.infinity;

  Map<String, dynamic> toJson() => {
        'provider': provider,
        'requests_min': _bucketJson(requestsMin),
        'requests_hour': _bucketJson(requestsHour),
        'tokens_min': _bucketJson(tokensMin),
        'tokens_hour': _bucketJson(tokensHour),
        'captured_at': capturedAt,
      };

  Map<String, dynamic> _bucketJson(RateLimitBucket b) => {
        'limit': b.limit,
        'remaining': b.remaining,
        'reset_seconds': b.resetSeconds,
        'used': b.used,
        'usage_pct': b.usagePct,
      };
}

int? _safeInt(Object? v) {
  if (v == null) return null;
  if (v is int) return v;
  return int.tryParse(v.toString());
}

double? _safeDouble(Object? v) {
  if (v == null) return null;
  if (v is num) return v.toDouble();
  return double.tryParse(v.toString());
}

/// Parse header (kunci apa pun casing-nya) menjadi [RateLimitState].
/// Header tidak ada → state kosong (hasData false) — fail-open.
RateLimitState parseRateLimitHeaders(
  Map<String, String> headers, {
  required String provider,
  required double Function() clock,
}) {
  final lower = <String, String>{
    for (final e in headers.entries) e.key.toLowerCase(): e.value,
  };

  RateLimitBucket? bucket(String tag) {
    final limit = _safeInt(lower['x-ratelimit-limit-$tag']);
    final remaining = _safeInt(lower['x-ratelimit-remaining-$tag']);
    final reset = _safeDouble(lower['x-ratelimit-reset-$tag']);
    if (limit == null && remaining == null && reset == null) return null;
    return RateLimitBucket(
      limit: limit ?? 0,
      remaining: remaining ?? 0,
      resetSeconds: reset ?? 0,
      capturedAt: clock(),
    );
  }

  final rm = bucket('requests');
  final rh = bucket('requests-1h');
  final tm = bucket('tokens');
  final th = bucket('tokens-1h');
  final any = rm != null || rh != null || tm != null || th != null;
  if (!any) {
    return RateLimitState(provider: provider);
  }
  return RateLimitState(
    requestsMin: rm,
    requestsHour: rh,
    tokensMin: tm,
    tokensHour: th,
    capturedAt: clock(),
    provider: provider,
  );
}

/// Tracker per provider — simpan state terakhir tiap provider untuk
/// perintah usage / observability.
class RateLimitTracker {
  final Map<String, RateLimitState> _states = {};

  RateLimitState? stateFor(String providerId) => _states[providerId];

  void update(RateLimitState state) {
    if (!state.hasData) return;
    _states[state.provider] = state;
  }

  /// Ringkasan satu baris per provider, untuk /usage.
  List<String> formatUsage({required double Function() clock}) {
    final lines = <String>[];
    _states.forEach((provider, s) {
      final b = s.requestsMin;
      if (b.limit > 0) {
        lines.add('$provider: ${b.used}/${b.limit} req '
            '(${b.usagePct.toStringAsFixed(0)}%) — '
            'reset ${b.remainingSecondsNow(clock: clock).toStringAsFixed(0)}s');
      }
      final th = s.tokensHour;
      if (th.limit > 0) {
        lines.add('$provider: ${th.used}/${th.limit} token/1h '
            '(${th.usagePct.toStringAsFixed(0)}%)');
      }
    });
    return lines;
  }
}

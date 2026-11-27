/// Klasifikasi error API provider + kebijakan recovery (Hermes
/// `turn_api_error.py`, `turn_overflow.py`, `turn_retry_state.py`).
///
/// Satu klasifikasi dipakai tiga konsumen: agent loop (recovery chain satu
/// kali sebelum fallback generik), router (apakah gagal dicatat ke provider),
/// dan UI (pesan terminal vs sementara). Klasifikasi murni deterministik —
/// tanpa jaringan, tanpa I/O.
enum ApiErrorKind {
  /// Kredensial ditolak (401/403) — rotasi kredensial/provider.
  auth,

  /// Kuota/rate limit (429) — backoff lalu fallback.
  rateLimit,

  /// Payload terlalu besar / konteks melebihi kapasitas (413,
  /// context_length_exceeded) — kompres lalu coba provider yang sama.
  overflow,

  /// Tagihan/entitlement ditolak (402 + pola billing) — terminal, jangan
  /// di-retry: percobaan ulang hanya mengulang penolakan yang sama.
  billing,

  /// Kesalahan sisi provider (5xx) — fallback.
  server,

  /// Jaringan/timeout/DNS — fallback.
  network,

  unknown,
}

class ApiError {
  const ApiError({
    required this.kind,
    this.statusCode,
    this.message = '',
  });

  final ApiErrorKind kind;
  final int? statusCode;
  final String message;

  /// Overflow dan rate-limit dipulihkan di provider yang sama sebelum
  /// fallback (overflow: kompres; rate limit: backoff). Billing terminal.
  bool get retrySameProvider =>
      kind == ApiErrorKind.overflow || kind == ApiErrorKind.rateLimit;

  /// Billing tidak pernah membaik dengan retry — hentikan turn dengan
  /// pesan terketik alih-alih menyeret fallback chain.
  bool get terminal => kind == ApiErrorKind.billing;

  bool get isTerminal => terminal;
}

class ApiErrorClassifier {
  const ApiErrorClassifier._();

  /// Pola Retry-After lintas provider: header/body `retry-after: N`,
  /// `retry in Ns`, `try again in N seconds`, `please retry after N`.
  static final _retryAfterBody = RegExp(
    r'(?:retry[\s_-]*(?:after|in)|try again in)[^0-9]{0,24}(\d{1,6})',
    caseSensitive: false,
  );

  /// Ambil `Retry-After` dalam detik dari kode status/pesan error
  /// (Hermes `provider_retry_after_seconds`). Null bila tidak ada/
  /// tidak valid — never raises.
  static int? retryAfterSecondsFrom({String? code, String? message}) {
    final sources = [if (code != null) code, if (message != null) message];
    for (final src in sources) {
      if (src.isEmpty) continue;
      final match = _retryAfterBody.firstMatch(src);
      if (match == null) continue;
      final value = int.tryParse(match.group(1)!);
      if (value == null || value <= 0) continue;
      return value;
    }
    return null;
  }

  /// Pola body/billing yang muncul lintas provider walau status bukan 402.
  static final _billingBody = RegExp(
    r'(insufficient[_ ]?(?:funds|quota|credits?)|billing|payment required|'
    r'exceeded your (?:current )?quota|credit balance)',
    caseSensitive: false,
  );

  /// Pola konteks overflow lintas provider (OpenAI, Anthropic, Ollama, vLLM).
  static final _overflowBody = RegExp(
    r'(context[_ ]length(?:[_ ]exceeded)?|maximum context (?:length|size)|'
    r'too many (?:tokens|input)|reduce the (?:length|number) of|'
    r'input (?:is )?too long|prompt is too long|payload too large)',
    caseSensitive: false,
  );

  /// Klasifikasikan dari kode status HTTP (string, bila provider
  /// menyediakannya) dan isi pesan/body error.
  static ApiError classify({String? code, String? message = ''}) {
    final msg = message ?? '';
    final status = int.tryParse(code ?? '') ?? _statusFromBody(msg);

    if (status == 402 || (status == null && _billingBody.hasMatch(msg))) {
      return ApiError(kind: ApiErrorKind.billing, statusCode: status, message: msg);
    }
    if (status == 401 || status == 403) {
      return ApiError(kind: ApiErrorKind.auth, statusCode: status, message: msg);
    }
    if (status == 429) {
      return ApiError(kind: ApiErrorKind.rateLimit, statusCode: status, message: msg);
    }
    if (status == 413 || (status != null && status >= 500)) {
      return ApiError(
        kind: status == 413 ? ApiErrorKind.overflow : ApiErrorKind.server,
        statusCode: status,
        message: msg,
      );
    }
    if (_overflowBody.hasMatch(msg)) {
      return ApiError(kind: ApiErrorKind.overflow, statusCode: status, message: msg);
    }
    if (status != null && status >= 400) {
      // 4xx lain yang menyebut billing/kuota tetap terminal; sisanya auth-
      // like request error yang tidak akan membaik dengan provider sama.
      return ApiError(
        kind: _billingBody.hasMatch(msg)
            ? ApiErrorKind.billing
            : ApiErrorKind.unknown,
        statusCode: status,
        message: msg,
      );
    }
    final lower = msg.toLowerCase();
    if (lower.contains('timeout') ||
        lower.contains('connection') ||
        lower.contains('socket') ||
        lower.contains('failed host lookup')) {
      return ApiError(kind: ApiErrorKind.network, message: msg);
    }
    return ApiError(kind: ApiErrorKind.unknown, statusCode: status, message: msg);
  }

  /// Ambil status dari awal pesan `'HTTP <status>: ...'` (format provider
  /// compat bawaan) bila provider tidak mengisi [code].
  static int? _statusFromBody(String msg) {
    final m = RegExp(r'HTTP (\d{3})').firstMatch(msg);
    return m == null ? null : int.tryParse(m.group(1)!);
  }
}

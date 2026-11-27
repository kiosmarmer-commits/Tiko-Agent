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

/// Hermes parity: `agent/error_classifier.py` — taksonomi granular
/// mengapa panggilan API gagal (menentukan strategi recovery).
enum FailoverReason {
  /// Auth transien (401/403) — refresh/rotasi kredensial lalu fallback.
  auth,

  /// 402 atau kehabisan kredit terkonfirmasi — terminal, rotasi langsung.
  billing,

  /// 429 / throttling kuota — backoff lalu rotasi.
  rateLimit,

  /// Konteks melebihi kapasitas — kompres lalu coba provider yang sama.
  contextLength,

  /// 5xx — fallback.
  serverError,

  /// Timeout/jaringan/DNS — fallback.
  network,

  /// Tidak terklasifikasi — tidak ada aksi otomatis.
  unknown,
}

/// Kode sintetis Hermes `PROVIDER_STREAM_NON_JSON_ERROR_CODE`: provider
/// mengirim frame SSE `data:` yang ditolak sebagai non-JSON sebelum chunk
/// pertama — distinkt dari JSON parse error generik (saran: non-streaming).
const String providerStreamNonJsonErrorCode = 'provider_stream_non_json_data';

/// Kode sintetis Hermes `PROVIDER_STREAM_EMPTY_FRAME_ERROR_CODE`: frame SSE
/// kosong (`data:` / `event: ping`) — legal per spesifikasi SSE, bukan
/// payload rusak; gateway terdegradasi menjawab semua request stream
/// dengannya → pindah ke non-streaming, bukan re-streaming.
const String providerStreamEmptyFrameErrorCode =
    'provider_stream_empty_frame';

/// Hasil klasifikasi granular + recovery hints ala Hermes: loop retry
/// mengkonsultasi hints ini alih-alih mencocokkan string sendiri.
class ClassifiedError {
  const ClassifiedError({
    required this.reason,
    this.retrySameProvider = false,
    this.compressFirst = false,
    this.rotateCredential = false,
    this.fallback = false,
    this.abort = false,
    this.retryAfterSec,
    this.suggestNonStreaming = false,
    this.syntheticCode,
  });

  final FailoverReason reason;

  /// Coba provider yang sama (setelah aksi [compressFirst] bila berlaku).
  final bool retrySameProvider;

  /// Kompres konteks dulu sebelum retry (overflow).
  final bool compressFirst;

  /// Rotasi kredensial dianjurkan (auth transien).
  final bool rotateCredential;

  /// Jalan ke fallback chain.
  final bool fallback;

  /// Hentikan turn dengan pesan terketik (billing terminal).
  final bool abort;

  final int? retryAfterSec;

  /// Gateway terdegradasi (frame SSE kosong / non-JSON) — saran: jalur
  /// non-streaming, bukan re-streaming ke window yang sama.
  final bool suggestNonStreaming;

  /// Kode sintetis (`provider_stream_*`) bila terdeteksi.
  final String? syntheticCode;

  Map<String, dynamic> toJson() => {
        'reason': reason.name,
        'retry_same_provider': retrySameProvider,
        'compress_first': compressFirst,
        'rotate_credential': rotateCredential,
        'fallback': fallback,
        'abort': abort,
        if (retryAfterSec != null) 'retry_after_sec': retryAfterSec,
        if (suggestNonStreaming) 'suggest_non_streaming': true,
        if (syntheticCode != null) 'synthetic_code': syntheticCode,
      };
}

final _streamNonJsonBody = RegExp(
  r'(provider_stream_non_json|unexpected token.*(data|sse)|'
  r'invalid.*sse.*(payload|data)|not valid json)',
  caseSensitive: false,
);

final _streamEmptyFrameBody = RegExp(
  r'(provider_stream_empty_frame|event:\s*ping|^\s*data:\s*$)',
  caseSensitive: false,
);

extension ApiErrorClassifierFailureTaxonomy on ApiErrorClassifier {
  /// Klasifikasi granular ala Hermes `error_classifier.py`: [ApiError]
  /// dasar (atau kode+pesan mentah) → [ClassifiedError] dengan recovery
  /// hints. Murni deterministik, never-raises.
  static ClassifiedError classifyFailure({
    String? code,
    String? message = '',
  }) {
    final base = ApiErrorClassifier.classify(code: code, message: message);
    final msg = message ?? '';
    final retryAfter = ApiErrorClassifier.retryAfterSecondsFrom(
      code: code,
      message: msg,
    );
    if (_streamEmptyFrameBody.hasMatch(msg)) {
      return ClassifiedError(
        reason: FailoverReason.serverError,
        fallback: true,
        suggestNonStreaming: true,
        syntheticCode: providerStreamEmptyFrameErrorCode,
      );
    }
    if (_streamNonJsonBody.hasMatch(msg)) {
      return ClassifiedError(
        reason: FailoverReason.serverError,
        fallback: true,
        suggestNonStreaming: true,
        syntheticCode: providerStreamNonJsonErrorCode,
      );
    }
    switch (base.kind) {
      case ApiErrorKind.auth:
        return ClassifiedError(
          reason: FailoverReason.auth,
          rotateCredential: true,
          fallback: true,
        );
      case ApiErrorKind.billing:
        return const ClassifiedError(
          reason: FailoverReason.billing,
          abort: true,
        );
      case ApiErrorKind.rateLimit:
        return ClassifiedError(
          reason: FailoverReason.rateLimit,
          retrySameProvider: true,
          retryAfterSec: retryAfter,
        );
      case ApiErrorKind.overflow:
        return const ClassifiedError(
          reason: FailoverReason.contextLength,
          retrySameProvider: true,
          compressFirst: true,
        );
      case ApiErrorKind.server:
        return const ClassifiedError(
          reason: FailoverReason.serverError,
          fallback: true,
        );
      case ApiErrorKind.network:
        return const ClassifiedError(
          reason: FailoverReason.network,
          fallback: true,
        );
      case ApiErrorKind.unknown:
        return ClassifiedError(reason: FailoverReason.unknown);
    }
  }
}

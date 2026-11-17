import 'dart:convert';

/// Kode error standar API (GUI-P0-03), selaras dengan error model daemon:
/// setiap respons error membawa `code`, `error` (pesan), dan `retryable`.
enum ApiErrorCode {
  unauthorized,
  forbidden,
  notFound,
  notImplemented,
  conflict,
  rateLimited,
  invalidRequest,
  server,
  network,
  timeout,
  unknown;

  static ApiErrorCode fromName(String? name) {
    for (final value in ApiErrorCode.values) {
      if (value.name == name) return value;
    }
    return unknown;
  }

  static ApiErrorCode fromStatus(int status) {
    switch (status) {
      case 400:
        return invalidRequest;
      case 401:
        return unauthorized;
      case 403:
        return forbidden;
      case 404:
        return notFound;
      case 409:
        return conflict;
      case 429:
        return rateLimited;
      case 501:
        return notImplemented;
      default:
        return status >= 500 ? server : unknown;
    }
  }
}

/// Error typed yang dilempar [AgentApiClient] dan repository; menggantikan
/// `Exception('...')` mentah sehingga UI bisa bereaksi per kode (mis. fallback
/// hanya untuk 501, pesan khusus untuk timeout/network).
class ApiError implements Exception {
  const ApiError({
    required this.code,
    required this.message,
    this.statusCode,
    this.retryable = false,
  });

  final ApiErrorCode code;
  final String message;
  final int? statusCode;
  final bool retryable;

  factory ApiError.fromResponse(int statusCode, String body) {
    var message = 'HTTP $statusCode';
    var code = ApiErrorCode.fromStatus(statusCode);
    var retryable = statusCode >= 500 || statusCode == 429;
    try {
      final json = jsonDecode(body);
      if (json is Map) {
        final rawMessage = json['error'] ?? json['message'];
        if (rawMessage is String && rawMessage.isNotEmpty) message = rawMessage;
        if (json['code'] is String) {
          final parsed = ApiErrorCode.fromName(json['code'] as String);
          if (parsed != ApiErrorCode.unknown) code = parsed;
        }
        if (json['retryable'] is bool) retryable = json['retryable'] as bool;
      }
    } catch (_) {
      // Body bukan JSON: pakai pemetaan status di atas.
    }
    return ApiError(
      code: code,
      message: message,
      statusCode: statusCode,
      retryable: retryable,
    );
  }

  factory ApiError.network(String message) => ApiError(
        code: ApiErrorCode.network,
        message: message,
        retryable: true,
      );

  factory ApiError.timeout(String message) => ApiError(
        code: ApiErrorCode.timeout,
        message: message,
        retryable: true,
      );

  @override
  String toString() => 'ApiError(${code.name}: $message)';
}

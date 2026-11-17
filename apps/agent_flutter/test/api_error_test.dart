import 'package:agent_flutter/data/api_error.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ApiError.fromResponse', () {
    test('mem-parse error model typed daemon', () {
      final err = ApiError.fromResponse(
        404,
        '{"ok":false,"code":"not_found","error":"session not found","retryable":false}',
      );
      expect(err.code, ApiErrorCode.notFound);
      expect(err.message, 'session not found');
      expect(err.statusCode, 404);
      expect(err.retryable, false);
    });

    test('fallback pemetaan status bila body bukan JSON typed', () {
      final err = ApiError.fromResponse(401, 'plain text');
      expect(err.code, ApiErrorCode.unauthorized);
      expect(err.message, 'HTTP 401');
    });

    test('501 dipetakan ke notImplemented untuk fallback UI action', () {
      final err = ApiError.fromResponse(501, '{"error":"ui actions not configured"}');
      expect(err.code, ApiErrorCode.notImplemented);
      expect(err.statusCode, 501);
    });

    test('5xx default retryable, pesan JSON biasa tetap terbaca', () {
      final err = ApiError.fromResponse(500, '{"error":"boom"}');
      expect(err.code, ApiErrorCode.server);
      expect(err.retryable, true);
      expect(err.message, 'boom');
    });

    test('kode tak dikenal tetap jatuh ke pemetaan status', () {
      final err = ApiError.fromResponse(
        429,
        '{"code":"alien_code","error":"slow down"}',
      );
      expect(err.code, ApiErrorCode.rateLimited);
      expect(err.message, 'slow down');
      expect(err.retryable, true);
    });
  });

  test('ApiError.network dan timeout retryable', () {
    expect(ApiError.network('refused').retryable, true);
    expect(ApiError.timeout('terlalu lama').code, ApiErrorCode.timeout);
    expect(ApiError.network('x').toString(), contains('network'));
  });
}

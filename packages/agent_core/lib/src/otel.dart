import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

/// OpenTelemetry-compatible trace export (P2): turns agent turns into OTLP
/// JSON spans over HTTP, with privacy-by-default.
///
/// - Opt-in: the exporter is a no-op unless an endpoint is configured
///   (`OTEL_EXPORTER_OTLP_ENDPOINT` at the host, or an explicit value).
/// - Privacy-by-default: prompt/answer content is never exported. Only
///   allow-listed attributes (durations, token counts, status, tool names)
///   leave the process.
/// - Best-effort: export failures are swallowed (a down collector must never
///   break the agent turn). Batched with a simple flush-on-size policy.

/// One finished span ready for export.
class OtelSpan {
  OtelSpan({
    required this.traceId,
    required this.spanId,
    required this.parentSpanId,
    required this.name,
    required this.startEpochMs,
    required this.endEpochMs,
    this.attributes = const {},
    this.statusError = false,
  });

  /// 32 hex chars (16 bytes), per W3C trace-id.
  final String traceId;

  /// 16 hex chars (8 bytes), per W3C span-id.
  final String spanId;
  final String parentSpanId;
  final String name;
  final int startEpochMs;
  final int endEpochMs;

  /// Allow-listed, non-sensitive attributes only.
  final Map<String, Object?> attributes;
  final bool statusError;

  Map<String, dynamic> toOtlpJson() => {
        'traceId': traceId,
        'spanId': spanId,
        'parentSpanId': parentSpanId,
        'name': name,
        'kind': 'SPAN_KIND_INTERNAL',
        'startTimeUnixNano': '${startEpochMs * 1000000}',
        'endTimeUnixNano': '${endEpochMs * 1000000}',
        'attributes': [
          for (final e in attributes.entries)
            {
              'key': e.key,
              'value': _attrValue(e.value),
            },
        ],
        'status': {
          'code': statusError ? 'STATUS_CODE_ERROR' : 'STATUS_CODE_OK',
        },
      };

  static Map<String, dynamic> _attrValue(Object? v) => switch (v) {
        final int i => {'intValue': '$i'},
        final double d => {'doubleValue': d},
        final bool b => {'boolValue': b},
        _ => {'stringValue': v?.toString() ?? ''},
      };
}

/// Attribute keys that may leave the process. Everything else recorded on a
/// span is dropped before export (privacy-by-default).
const otelAllowedAttributeKeys = {
  'tiko.session_id',
  'tiko.channel',
  'tiko.provider',
  'tiko.model',
  'tiko.tokens_used',
  'tiko.tool_call_count',
  'tiko.success',
  'tiko.duration_ms',
  'tiko.tool_name',
  'tiko.tool_error',
};

/// Filters span attributes down to the allow-list.
Map<String, Object?> otelFilterAttributes(Map<String, Object?> attributes) => {
      for (final e in attributes.entries)
        if (otelAllowedAttributeKeys.contains(e.key)) e.key: e.value,
    };

/// Posts OTLP/JSON trace batches to an OTLP/HTTP endpoint.
class OtlpHttpTraceExporter {
  OtlpHttpTraceExporter({
    required this.endpoint,
    this.serviceName = 'tiko-agent',
    this.batchSize = 32,
    Map<String, String>? headers,
  }) : _headers = headers ?? const {};

  /// OTLP/HTTP endpoint, e.g. `http://127.0.0.1:4318/v1/traces`.
  final String endpoint;
  final String serviceName;
  final int batchSize;
  final Map<String, String> _headers;

  final List<OtelSpan> _pending = [];
  HttpClient? _client;

  /// Buffers a span; flushes when the batch is full. Never throws.
  Future<void> export(OtelSpan span) async {
    _pending.add(span);
    if (_pending.length >= batchSize) {
      await flush();
    }
  }

  /// Sends all pending spans. Failures are swallowed by design.
  Future<void> flush() async {
    if (_pending.isEmpty) return;
    final batch = List<OtelSpan>.of(_pending);
    _pending.clear();
    try {
      final client = _client ??= HttpClient()..connectionTimeout = const Duration(seconds: 5);
      final request = await client.postUrl(Uri.parse(endpoint));
      request.headers.contentType = ContentType('application', 'json');
      _headers.forEach(request.headers.set);
      request.write(jsonEncode({
        'resourceSpans': [
          {
            'resource': {
              'attributes': [
                {
                  'key': 'service.name',
                  'value': {'stringValue': serviceName},
                },
              ],
            },
            'scopeSpans': [
              {
                'scope': {'name': 'tiko.agent'},
                'spans': [for (final s in batch) s.toOtlpJson()],
              },
            ],
          },
        ],
      }));
      final response = await request.close().timeout(const Duration(seconds: 10));
      // Drain so the socket is reusable; status is intentionally ignored
      // (observability must be side-effect free for the agent).
      await response.drain<void>();
    } catch (_) {
      // Best-effort: drop the batch on failure.
    }
  }

  Future<void> close() async {
    await flush();
    _client?.close(force: true);
    _client = null;
  }
}

/// Records agent-turn spans and forwards them to an optional exporter.
/// With a null exporter everything is a cheap no-op.
class SpanRecorder {
  SpanRecorder({OtlpHttpTraceExporter? exporter}) : _exporter = exporter;

  final OtlpHttpTraceExporter? _exporter;
  final Set<Future<void>> _inFlight = {};

  bool get isEnabled => _exporter != null;

  /// Records one agent turn as a span. [attributes] are filtered through the
  /// privacy allow-list before export.
  Future<void> recordTurn({
    required String traceId,
    required Map<String, Object?> attributes,
    required int startEpochMs,
    required int endEpochMs,
    required bool success,
    String spanName = 'agent.turn',
  }) async {
    final exporter = _exporter;
    if (exporter == null) return;
    final span = OtelSpan(
      traceId: traceId,
      spanId: _randomHex(8),
      parentSpanId: '0' * 16,
      name: spanName,
      startEpochMs: startEpochMs,
      endEpochMs: endEpochMs,
      attributes: otelFilterAttributes(attributes),
      statusError: !success,
    );
    final future = exporter.export(span);
    _inFlight.add(future);
    unawaited(future.whenComplete(() => _inFlight.remove(future)));
  }

  Future<void> close() async {
    if (_inFlight.isNotEmpty) {
      await Future.wait(_inFlight).timeout(const Duration(seconds: 2), onTimeout: () => []);
    }
    await _exporter?.close();
  }
}

final _hexRandom = Random.secure();

String _randomHex(int bytes) => [
      for (var i = 0; i < bytes * 2; i++)
        '0123456789abcdef'[_hexRandom.nextInt(16)],
    ].join();

import 'dart:convert';
import 'dart:io';

import 'package:agent_core/agent_core.dart';
import 'package:test/test.dart';

void main() {
  test('otelFilterAttributes drops everything outside the allow-list', () {
    final filtered = otelFilterAttributes({
      'tiko.session_id': 's1',
      'tiko.tokens_used': 42,
      'tiko.success': true,
      'prompt.text': 'RAHASIA',
      'answer.text': 'JUGA RAHASIA',
      'tiko.tool_name': 'read_file',
    });
    expect(filtered.keys.toSet(), {'tiko.session_id', 'tiko.tokens_used', 'tiko.success', 'tiko.tool_name'});
    expect(jsonEncode(filtered), isNot(contains('RAHASIA')));
  });

  test('OtlpHttpTraceExporter posts OTLP JSON to the endpoint', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final bodies = <Map<String, dynamic>>[];
    server.listen(
      (req) async {
        final body = await utf8.decoder.bind(req).join();
        bodies.add(jsonDecode(body) as Map<String, dynamic>);
        req.response.statusCode = 200;
        await req.response.close();
      },
      onError: (Object _) {},
    );
    addTearDown(() => server.close(force: true));

    final exporter = OtlpHttpTraceExporter(
      endpoint: 'http://127.0.0.1:${server.port}/v1/traces',
      batchSize: 1,
    );
    final recorder = SpanRecorder(exporter: exporter);
    await recorder.recordTurn(
      traceId: 'abc123',
      attributes: {
        'tiko.session_id': 's1',
        'tiko.tokens_used': 99,
        'prompt.text': 'JANGAN IKUT',
      },
      startEpochMs: 1700000000000,
      endEpochMs: 1700000001500,
      success: true,
    );
    await recorder.close();

    expect(bodies, hasLength(1));
    final resourceSpans = bodies.single['resourceSpans'] as List;
    final spans = ((resourceSpans.first as Map)['scopeSpans'] as List)
        .first['spans'] as List;
    final span = spans.first as Map;
    expect(span['traceId'], 'abc123');
    expect(span['name'], 'agent.turn');
    final attrs = {
      for (final a in span['attributes'] as List) a['key']: a['value'],
    };
    expect(attrs['tiko.tokens_used'], {'intValue': '99'});
    expect(attrs.containsKey('prompt.text'), isFalse);
    expect(jsonEncode(bodies.single), isNot(contains('JANGAN IKUT')));
  });

  test('SpanRecorder without an exporter is a no-op', () async {
    final recorder = SpanRecorder();
    expect(recorder.isEnabled, isFalse);
    await recorder.recordTurn(
      traceId: 't',
      attributes: const {},
      startEpochMs: 0,
      endEpochMs: 1,
      success: true,
    );
    await recorder.close();
  });

  test('export failures never throw and never break the caller', () async {
    final exporter = OtlpHttpTraceExporter(
      endpoint: 'http://127.0.0.1:1/v1/traces',
      batchSize: 1,
    );
    await exporter.export(OtelSpan(
      traceId: 't',
      spanId: 'a' * 16,
      parentSpanId: '0' * 16,
      name: 'x',
      startEpochMs: 0,
      endEpochMs: 1,
    ));
    await exporter.close();
  });
}

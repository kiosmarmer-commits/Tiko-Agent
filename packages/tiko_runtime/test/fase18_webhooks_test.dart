// Hermes fase-18: webhook outbound (`agent/webhook_outbound.py`) — POST
// event runtime ke endpoint `webhooks.outbound` dengan tanda tangan HMAC.
// Penerima diuji pakai HttpServer loopback; tanda tangan diverifikasi penuh.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:test/test.dart';
import 'package:tiko_runtime/tiko_runtime.dart';

void main() {
  late HttpServer server;
  final received = <Map<String, dynamic>>[];
  late Completer<void> got;

  setUp(() async {
    received.clear();
    got = Completer<void>();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      final body = await utf8.decoder.bind(req).join();
      received.add({
        'path': req.uri.path,
        'signature': req.headers.value('x-tiko-signature'),
        'body': body,
      });
      req.response.statusCode = 200;
      await req.response.close();
      if (!got.isCompleted) got.complete();
    });
  });

  tearDown(() async {
    await server.close(force: true);
  });

  test('POST JSON + header HMAC-SHA256 hex atas body', () async {
    final bus = EventBus();
    final hooks = [
      OutboundWebhookConfig(
        url: 'http://127.0.0.1:${server.port}/hook',
        secret: 's3cret',
      ),
    ];
    final reg2 = OutboundWebhookRegistry(hooks)..start(bus);
    addTearDown(reg2.close);
    addTearDown(bus.close);

    bus.emit('turn.completed', {'session': 's1'});
    await got.future.timeout(const Duration(seconds: 5));
    expect(received, hasLength(1));
    expect(received.single['path'], '/hook');
    final body = received.single['body'] as String;
    final decoded = jsonDecode(body) as Map<String, dynamic>;
    expect(decoded['type'], 'turn.completed');
    expect((decoded['data'] as Map)['session'], 's1');
    final sig = received.single['signature'] as String?;
    expect(sig, isNotNull);
    expect(sig!.startsWith('sha256='), isTrue);
    final expected = Hmac(sha256, utf8.encode('s3cret'))
        .convert(utf8.encode(body))
        .toString();
    expect(sig.substring('sha256='.length), expected);
  });

  test('filter events: tipe tak cocok tidak dikirim', () async {
    final bus = EventBus();
    final reg = OutboundWebhookRegistry([
      OutboundWebhookConfig(
        url: 'http://127.0.0.1:${server.port}/only-cost',
        events: const ['cost.*'],
      ),
    ])..start(bus);
    addTearDown(reg.close);
    addTearDown(bus.close);

    bus.emit('turn.completed', {});
    bus.emit('cost.recorded', {'usd': 0.1});
    await got.future.timeout(const Duration(seconds: 5));
    expect(received, hasLength(1));
    expect(
      (jsonDecode(received.single['body']) as Map)['type'],
      'cost.recorded',
    );
  });

  test('gagal jaringan tidak pernah melempar; counter failed naik', () async {
    final bus = EventBus();
    final reg = OutboundWebhookRegistry([
      const OutboundWebhookConfig(url: 'http://127.0.0.1:1/unreachable'),
    ])..start(bus);
    addTearDown(reg.close);
    addTearDown(bus.close);

    bus.emit('turn.completed', {});
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(reg.failed, 1);
    expect(reg.delivered, 0);
  });

  test('config parse: webhooks.outbound tervalidasi fail-open', () async {
    final (cfg, issues) = TikoConfig.parse('''
profile: default
webhooks:
  outbound:
    - url: https://example.com/hook
      secret: topsecret
      events: [turn.completed, cost.*]
    - url: not-a-url
''');
    expect(cfg.webhookOutbound, hasLength(1));
    expect(cfg.webhookOutbound.single.url, 'https://example.com/hook');
    expect(cfg.webhookOutbound.single.secret, 'topsecret');
    expect(cfg.webhookOutbound.single.events, ['turn.completed', 'cost.*']);
    expect(
      issues.any((i) => i.path.contains('webhooks.outbound[1].url')),
      isTrue,
      reason: 'entri invalid dilompati dengan issue eksplisit',
    );
  });
}

import 'dart:io';

import 'package:agent_providers/agent_providers.dart';
import 'package:tiko_runtime/tiko_runtime.dart';
import 'package:test/test.dart';

void main() {
  late Directory temp;
  late TikoRuntime rt;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('tiko-unified-health-');
    await Directory('${temp.path}/skills').create(recursive: true);
    await File('${temp.path}/agent.yaml').writeAsString('''
profile: default
workspace: "."
providers:
  default_chat: mock
  chat:
    mock:
      type: mock
''');
    rt = await TikoRuntime.create(configPath: '${temp.path}/agent.yaml');
  });

  tearDown(() async {
    await rt.close();
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  test('breakerFor berbagi state ProviderHealth dengan Router', () {
    final providerId = rt.config.defaultProvider;
    final breaker = rt.breakerFor(providerId);

    expect(breaker.state, 'closed');
    expect(rt.providerHealth()[providerId]['phase'], 'closed');

    breaker.recordFailure('boom');
    breaker.recordFailure('boom');
    breaker.recordFailure('boom');

    // Failure recorded through the breaker is instantly visible in the
    // Router's health snapshot — one state machine, not two counters.
    expect(rt.providerHealth()[providerId]['phase'], 'open');
    expect(rt.providerHealth()[providerId]['failures'], 3);
    expect(breaker.isOpen, isTrue);
    expect(breaker.tryAcquire(), isFalse);
  });

  test('kegagalan yang dicatat Router terlihat oleh breaker (arah sebaliknya)',
      () {
    final providerId = rt.config.defaultProvider;
    rt.recordProviderFailure(providerId, 'timeout');
    rt.recordProviderFailure(providerId, 'timeout');

    final breaker = rt.breakerFor(providerId);
    expect(breaker.state, 'closed');
    breaker.recordFailure('timeout');
    expect(breaker.isOpen, isTrue);
  });

  test('sukses menutup breaker dan menghapus failures bersama', () {
    final providerId = rt.config.defaultProvider;
    final breaker = rt.breakerFor(providerId);
    breaker.recordFailure('x');
    breaker.recordFailure('x');
    breaker.recordFailure('x');
    expect(breaker.isOpen, isTrue);

    breaker.recordSuccess(latencyMs: 42);
    expect(breaker.state, 'closed');
    final snapshot = rt.providerHealth()[providerId];
    expect(snapshot['failures'], 0);
    expect(snapshot['last_latency_ms'], 42);
  });

  test('CircuitBreaker tanpa injeksi membuat state sendiri (backward-compat)',
      () {
    final standalone = CircuitBreaker();
    standalone.recordFailure('x');
    standalone.recordFailure('x');
    standalone.recordFailure('x');
    expect(standalone.isOpen, isTrue);
    expect(standalone.state, 'open');
  });
}

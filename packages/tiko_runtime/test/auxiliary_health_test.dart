import 'dart:io';

import 'package:agent_core/agent_core.dart';
import 'package:agent_providers/agent_providers.dart';
import 'package:test/test.dart';
import 'package:tiko_runtime/tiko_runtime.dart';

void main() {
  late Directory temp;
  late TikoRuntime rt;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('tiko-aux-health-');
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

  LlmProvider aux() => rt.auxiliaryLlm()!;

  test('jalur auxiliar memakai objek ProviderHealth yang identik dengan Router',
      () {
    final providerId = rt.config.defaultProvider;
    final wrapper = aux() as BreakerLlmProvider;
    expect(identical(wrapper.breaker.health, rt.breakerFor(providerId).health), isTrue);
    expect(wrapper.id, providerId);
  });

  test('SelfLearningEngine dan synth path terhubung ke health bersama', () {
    final providerId = rt.config.defaultProvider;
    final engineProvider = rt.selfLearningEngine!.llmProvider;
    expect(engineProvider, isA<BreakerLlmProvider>());
    expect(
      identical(
        (engineProvider as BreakerLlmProvider).breaker.health,
        rt.breakerFor(providerId).health,
      ),
      isTrue,
    );
  });

  test('kegagalan yang dicatat Router men-gate jalur auxiliar (breaker_open)',
      () async {
    final providerId = rt.config.defaultProvider;
    for (var i = 0; i < 3; i++) {
      rt.recordProviderFailure(providerId, 'timeout');
    }
    expect(rt.breakerFor(providerId).isOpen, isTrue);

    final events = await aux().chat(
      ChatRequest(
        model: providerId,
        messages: const [ChatMessage(role: 'user', content: 'hai')],
      ),
    ).toList();
    expect(events.single, isA<LlmError>());
    final err = events.single as LlmError;
    expect(err.code, 'breaker_open');
  });

  test('kegagalan jalur auxiliar terlihat di snapshot health Router', () async {
    final providerId = rt.config.defaultProvider;
    final wrapper = aux() as BreakerLlmProvider;
    wrapper.breaker.recordFailure('reflection gagal');
    wrapper.breaker.recordFailure('reflection gagal');

    final snapshot = rt.providerHealth();
    expect(snapshot[providerId]['failures'], 2);
    expect(snapshot[providerId]['last_error'], 'reflection gagal');
  });
}

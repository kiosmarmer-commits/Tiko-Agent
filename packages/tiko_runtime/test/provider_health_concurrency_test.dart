import 'dart:async';
import 'dart:io';

import 'package:agent_core/agent_core.dart';
import 'package:agent_providers/agent_providers.dart';
import 'package:tiko_runtime/tiko_runtime.dart';
import 'package:test/test.dart';

/// Provider palsu yang stream-nya dikendalikan lewat [StreamController]
/// — dipakai untuk menguji pembatalan stream tanpa verdict.
class _HangingProvider implements LlmProvider {
  final controller = StreamController<LlmEvent>();

  @override
  String get id => 'hanging';

  @override
  Capabilities get capabilities => const Capabilities();

  @override
  Stream<LlmEvent> chat(ChatRequest req) => controller.stream;

  @override
  Future<List<double>> embed(String text) async => const [];
}

const _req = ChatRequest(messages: [ChatMessage(role: 'user', content: 'hai')]);

void main() {
  late Directory temp;
  late TikoRuntime rt;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('tiko-health-conc-');
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

  test('N pemanggil paralel ditolak saat breaker terbuka (Future.wait)', () async {
    final providerId = rt.config.defaultProvider;
    final breaker = rt.breakerFor(providerId);
    breaker.recordFailure('boom');
    breaker.recordFailure('boom');
    breaker.recordFailure('boom');
    expect(breaker.isOpen, isTrue);

    // 20 pemanggil "konkuren" mencoba slot pada fase open — semua harus
    // ditolak dan TIDAK boleh mencatat kegagalan baru (tanpa double-count).
    final results = await Future.wait(
      List.generate(20, (_) async {
        await Future<void>.delayed(Duration.zero);
        return rt.breakerFor(providerId).tryAcquire();
      }),
    );
    expect(results.where((r) => r), isEmpty);

    final snapshot = rt.providerHealth()[providerId];
    expect(snapshot['phase'], 'open');
    expect(snapshot['failures'], 3, reason: 'panggilan yang ditolak breaker '
        'tidak boleh menambah penghitung kegagalan');
  });

  test('kegagalan paralel dari banyak pemanggil membuka breaker persis di ambang',
      () async {
    final providerId = rt.config.defaultProvider;

    // 10 pemanggil paralel mencatat kegagalan lewat permukaan runtime.
    await Future.wait(
      List.generate(10, (i) async {
        await Future<void>.delayed(Duration.zero);
        rt.recordProviderFailure(providerId, 'err-$i');
      }),
    );

    final snapshot = rt.providerHealth()[providerId];
    expect(snapshot['failures'], 10,
        reason: 'setiap pemanggilan recordProviderFailure tercatat tepat '
            'satu kali — tidak ada update yang hilang');
    expect(snapshot['phase'], 'open');
    expect(rt.breakerFor(providerId).tryAcquire(), isFalse);
  });

  test('half-open: tepat SATU pemenang probe dari N pemanggil paralel', () async {
    var now = DateTime.utc(2026, 11, 16, 12, 0, 0);
    final health = ProviderHealth(
      clock: () => now,
      failureThreshold: 3,
      openDuration: const Duration(seconds: 60),
    );

    health.recordFailure('a');
    health.recordFailure('b');
    health.recordFailure('c');
    expect(health.state, 'open');

    // Majukan clock melewati jendela open → half-open.
    now = now.add(const Duration(seconds: 61));
    expect(health.state, 'half_open');

    // 20 pemanggil paralel berebut satu slot probe — tepat satu pemenang.
    final results = await Future.wait(
      List.generate(20, (_) async {
        await Future<void>.delayed(Duration.zero);
        return health.tryAcquire();
      }),
    );
    expect(results.where((r) => r).length, 1,
        reason: 'single-probe half-open: hanya pemanggil pertama yang menang');
    expect(health.selectable, isFalse,
        reason: 'selama probe berjalan, provider tidak selectable');

    // Slot dilepas tanpa verdict → pemanggil berikutnya boleh probe lagi.
    health.releaseProbe();
    expect(health.tryAcquire(), isTrue);
    expect(health.tryAcquire(), isFalse);
  });

  test('probe sukses dari satu pemenang menutup breaker untuk semua', () async {
    var now = DateTime.utc(2026, 11, 16, 12, 0, 0);
    final health = ProviderHealth(
      clock: () => now,
      failureThreshold: 2,
      openDuration: const Duration(seconds: 30),
    );
    health.recordFailure('x');
    health.recordFailure('x');
    now = now.add(const Duration(seconds: 31));
    expect(health.state, 'half_open');

    final winners = <bool>[];
    await Future.wait(
      List.generate(10, (_) async {
        await Future<void>.delayed(Duration.zero);
        if (health.tryAcquire()) winners.add(true);
      }),
    );
    expect(winners.length, 1);

    health.recordSuccess(12.5);
    expect(health.state, 'closed');

    // Setelah sukses probe, semua pemanggil paralel kembali dilayani.
    final all = await Future.wait(
      List.generate(10, (_) async => health.tryAcquire()),
    );
    expect(all.where((r) => r).length, 10);
  });

  test('BreakerLlmProvider: stream dibatalkan tanpa verdict melepas slot probe',
      () async {
    var now = DateTime.utc(2026, 11, 16, 12, 0, 0);
    final health = ProviderHealth(
      clock: () => now,
      failureThreshold: 1,
      openDuration: const Duration(seconds: 30),
    );
    final inner = _HangingProvider();
    final wrapped = BreakerLlmProvider(inner, health: health);

    // Buka breaker, lalu masuk half-open.
    health.recordFailure('down');
    now = now.add(const Duration(seconds: 31));
    expect(health.state, 'half_open');

    // Mulai stream dan batalkan saat menerima event pertama — pola nyata
    // konsumen (mis. timeout/abort). Pemotongan di titik yield menjalankan
    // finally pada generator async* tanpa verdict.
    late final StreamSubscription<LlmEvent> sub;
    sub = wrapped.chat(_req).listen((_) {
      sub.cancel();
    });
    inner.controller.add(const LlmTextDelta('sebagian'));
    inner.controller.add(const LlmTextDelta('lanjutan'));
    // Beri kesempatan finally pada generator async* berjalan.
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    // Regresi: slot probe TIDAK boleh macet selamanya.
    expect(health.tryAcquire(), isTrue,
        reason: 'pembatalan tanpa verdict harus melepas slot probe half-open');
    await inner.controller.close();
  });

  test('auxiliaryLlm paralel saat breaker open: semua ditolak breaker_open, '
      'failures tidak berubah', () async {
    final providerId = rt.config.defaultProvider;
    rt.recordProviderFailure(providerId, 'down-1');
    rt.recordProviderFailure(providerId, 'down-2');
    rt.recordProviderFailure(providerId, 'down-3');
    expect(rt.providerHealth()[providerId]['phase'], 'open');

    final aux = rt.auxiliaryLlm();
    expect(aux, isNotNull);

    final codes = await Future.wait(
      List.generate(8, (_) async {
        await Future<void>.delayed(Duration.zero);
        final event = await aux!.chat(_req).first;
        return event is LlmError ? (event.code ?? '') : 'ok';
      }),
    );
    expect(codes.where((c) => c != 'breaker_open'), isEmpty,
        reason: 'semua stream paralel harus ditolak fail-closed saat open');

    final snapshot = rt.providerHealth()[providerId];
    expect(snapshot['failures'], 3,
        reason: 'panggilan yang diblokir breaker tidak boleh dicatat '
            'sebagai kegagalan baru (tanpa double-count)');
  });
}

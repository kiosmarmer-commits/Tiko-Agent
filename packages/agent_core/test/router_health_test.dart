import 'package:agent_core/agent_core.dart';
import 'package:test/test.dart';

class _FailProvider implements LlmProvider {
  _FailProvider([this.nid = 'fail']);
  final String nid;
  @override
  String get id => nid;
  @override
  Capabilities get capabilities => const Capabilities(toolCalling: false);
  @override
  Stream<LlmEvent> chat(ChatRequest request) async* {
    yield const LlmError('down');
  }
  @override
  Future<List<double>> embed(String text) async => const [];
}

class _OkProvider implements LlmProvider {
  _OkProvider([this.nid = 'ok']);
  final String nid;
  @override
  String get id => nid;
  @override
  Capabilities get capabilities => const Capabilities(toolCalling: true);
  @override
  Stream<LlmEvent> chat(ChatRequest request) async* {
    yield const LlmTextDelta('ok');
    yield const LlmDone();
  }
  @override
  Future<List<double>> embed(String text) async => const [];
}

class _FakeClock {
  DateTime now = DateTime.utc(2026, 1, 1);

  DateTime call() => now;
}

void main() {
  test('ProviderHealth: fase dan single-probe half-open deterministik', () {
    final clock = _FakeClock();
    final h = ProviderHealth(clock: clock.call);
    expect(h.state, 'closed');
    expect(h.tryAcquire(), isTrue);
    h.recordFailure('e1');
    h.recordFailure('e2');
    expect(h.isOpen, isFalse);
    h.recordFailure('e3');
    expect(h.isOpen, isTrue);
    expect(h.state, 'open');
    expect(h.tryAcquire(), isFalse);
    expect(h.toJson()['phase'], 'open');
    clock.now = clock.now.add(const Duration(seconds: 60));
    expect(h.state, 'half_open');
    expect(h.tryAcquire(), isTrue);
    expect(h.tryAcquire(), isFalse);
    h.releaseProbe();
    expect(h.tryAcquire(), isTrue);
    h.recordFailure('e4');
    expect(h.state, 'open');
    clock.now = clock.now.add(const Duration(seconds: 60));
    expect(h.tryAcquire(), isTrue);
    h.recordSuccess(12.5);
    expect(h.state, 'closed');
    expect(h.failures, 0);
  });

  test('half-open: hanya satu probe lewat route, pemanggil lain dialihkan', () async {
    final clock = _FakeClock();
    final r = Router(
      providers: {'sick': _FailProvider('sick'), 'ok': _OkProvider('ok')},
      defaultProviderId: 'sick',
      fallbackOrder: ['ok'],
      clock: clock.call,
    );
    final s = Session(id: 's', channel: 't', userKey: 'u');
    r.recordFailure('sick', 'e1');
    r.recordFailure('sick', 'e2');
    r.recordFailure('sick', 'e3');
    expect(r.health['sick']!.isOpen, isTrue);
    clock.now = clock.now.add(const Duration(seconds: 60));
    final probe = await r.route('halo', s);
    expect(probe.providerId, 'sick');
    final concurrent = await r.route('halo', s);
    expect(concurrent.providerId, 'ok');
    r.recordSuccess('sick', 5);
    final closed = await r.route('halo', s);
    expect(closed.providerId, 'sick');
  });

  test('probe half-open gagal membuka ulang jendela penuh', () async {
    final clock = _FakeClock();
    final r = Router(
      providers: {'sick': _FailProvider('sick'), 'ok': _OkProvider('ok')},
      defaultProviderId: 'sick',
      fallbackOrder: ['ok'],
      clock: clock.call,
    );
    final s = Session(id: 's', channel: 't', userKey: 'u');
    r.recordFailure('sick', 'e1');
    r.recordFailure('sick', 'e2');
    r.recordFailure('sick', 'e3');
    clock.now = clock.now.add(const Duration(seconds: 60));
    final probe = await r.route('halo', s);
    expect(probe.providerId, 'sick');
    r.recordFailure('sick', 'probe gagal');
    expect(r.health['sick']!.isOpen, isTrue);
    final after = await r.route('halo', s);
    expect(after.providerId, 'ok');
  });

  test('explain tidak memegang slot probe half-open', () async {
    final clock = _FakeClock();
    final r = Router(
      providers: {'sick': _FailProvider('sick'), 'ok': _OkProvider('ok')},
      defaultProviderId: 'sick',
      fallbackOrder: ['ok'],
      clock: clock.call,
    );
    final s = Session(id: 's', channel: 't', userKey: 'u');
    r.recordFailure('sick', 'e1');
    r.recordFailure('sick', 'e2');
    r.recordFailure('sick', 'e3');
    clock.now = clock.now.add(const Duration(seconds: 60));
    final e = await r.explain('halo', s);
    final healthMap = e['health'] as Map<String, dynamic>;
    expect(healthMap['sick']!['phase'], 'half_open');
    final after = await r.route('halo', s);
    expect(after.providerId, 'sick');
  });

  test('seluruh provider open: route gagal-closed dan tidak bypass breaker', () async {
    final clock = _FakeClock();
    final r = Router(
      providers: {'a': _FailProvider('a'), 'b': _FailProvider('b')},
      defaultProviderId: 'a',
      clock: clock.call,
    );
    final s = Session(id: 's', channel: 't', userKey: 'u');
    for (final id in ['a', 'b']) {
      r.recordFailure(id, 'e1');
      r.recordFailure(id, 'e2');
      r.recordFailure(id, 'e3');
    }
    await expectLater(
      r.route('halo', s),
      throwsA(isA<NoHealthyProviderException>()),
    );
    final explained = await r.explain('halo', s);
    expect(explained['available'], isFalse);
    expect(explained['health'], contains('a'));
  });
}

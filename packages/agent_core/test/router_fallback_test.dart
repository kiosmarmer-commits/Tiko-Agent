import 'package:agent_core/agent_core.dart';
import 'package:test/test.dart';

class _FailProvider implements LlmProvider {
  @override
  String get id => 'fail';
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
  @override
  String get id => 'ok';
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

void main() {
  test('explain includes provider and fallbacks', () async {
    final r = Router(
      providers: {'fail': _FailProvider(), 'ok': _OkProvider()},
      defaultProviderId: 'fail',
      fallbackOrder: ['ok'],
    );
    final s = Session(id: 's', channel: 't', userKey: 'u');
    final d = await r.route('halo', s);
    expect(d.providerId, isNotEmpty);
    expect(d.reason, isNotEmpty);
    expect(d.fallbackIds, contains('ok'));
  });

  test('nextFallback does not double-count the recorded failure', () {
    final r = Router(
      providers: {'fail': _FailProvider(), 'ok': _OkProvider()},
      defaultProviderId: 'fail',
    );
    r.recordFailure('fail', 'single failure');
    final next = r.nextFallback(
      RouteDecision(llm: _FailProvider(), providerId: 'fail', fallbackIds: ['ok']),
      'fail',
    );
    expect(next?.id, 'ok');
    expect(r.health['fail']!.failures, 1);
    expect(r.fallbackEvents().single['to'], 'ok');
  });

  test('nextFallback honors excluded provider ids', () {
    final r = Router(
      providers: {
        'p1': _FailProvider(),
        'p2': _FailProvider(),
        'p3': _OkProvider(),
      },
      defaultProviderId: 'p1',
      fallbackOrder: ['p1', 'p2', 'p3'],
    );
    final route = RouteDecision(
      llm: _FailProvider(), providerId: 'p1', fallbackIds: ['p2', 'p3'],
    );
    expect(r.nextFallback(route, 'p1', exclude: {'p1'})?.id, 'p2');
    expect(r.nextFallback(route, 'p2', exclude: {'p1', 'p2'})?.id, 'p3');
  });

  test('circuit opens after failures', () {
    final r = Router(
      providers: {'fail': _FailProvider(), 'ok': _OkProvider()},
      defaultProviderId: 'fail',
    );
    r.recordFailure('fail', 'e1');
    r.recordFailure('fail', 'e2');
    r.recordFailure('fail', 'e3');
    expect(r.health['fail']!.isOpen, isTrue);
    final next = r.nextFallback(
      RouteDecision(llm: _FailProvider(), providerId: 'fail', fallbackIds: ['ok']),
      'fail',
    );
    expect(next?.id, 'ok');
  });
}

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

class _FixedDecision implements DecisionProvider {
  const _FixedDecision(this.complexity);

  final String complexity;

  @override
  Future<DecisionResult> decide(
    String state,
    Map<String, Question> questions,
  ) async {
    final answers = <String, Answer>{};
    for (final entry in questions.entries) {
      final question = entry.value;
      if (question is NoulQuestion) {
        answers[entry.key] = const Answer(type: 'noul', noul: 0.0);
      } else if (question is ChoiceQuestion) {
        answers[entry.key] = entry.key == 'kompleksitas'
            ? Answer(type: 'choice', choice: complexity)
            : Answer(type: 'choice', choice: question.options.first);
      } else {
        answers[entry.key] = const Answer(type: 'score', score: 0.0);
      }
    }
    return DecisionResult(answers);
  }
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
        'p1': _FailProvider('p1'),
        'p2': _FailProvider('p2'),
        'p3': _OkProvider('p3'),
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

  test('tier routing memilih provider sesuai keputusan decision model', () async {
    final s = Session(id: 's', channel: 't', userKey: 'u');
    final berat = Router(
      providers: {
        'kecil': _OkProvider('kecil'),
        'besar': _FailProvider('besar'),
      },
      defaultProviderId: 'kecil',
      decision: const _FixedDecision('berat'),
      tierProviders: const {1: 'kecil', 3: 'besar'},
    );
    final dBerat = await berat.route('analisis mendalam', s);
    expect(dBerat.tier, 3);
    expect(dBerat.providerId, 'besar');

    final ringan = Router(
      providers: {
        'kecil': _OkProvider('kecil'),
        'besar': _FailProvider('besar'),
      },
      defaultProviderId: 'kecil',
      decision: const _FixedDecision('ringan'),
      tierProviders: const {1: 'kecil', 3: 'besar'},
    );
    final dRingan = await ringan.route('halo', s);
    expect(dRingan.tier, 1);
    expect(dRingan.providerId, 'kecil');
  });

  test('tier tanpa pemetaan jatuh ke provider default', () async {
    final r = Router(
      providers: {'kecil': _OkProvider('kecil')},
      defaultProviderId: 'kecil',
      decision: const _FixedDecision('berat'),
    );
    final s = Session(id: 's', channel: 't', userKey: 'u');
    final d = await r.route('sangat berat', s);
    expect(d.tier, 3);
    expect(d.providerId, 'kecil');
  });

  test('explain menampilkan pemetaan tier', () async {
    final r = Router(
      providers: {'kecil': _OkProvider('kecil')},
      defaultProviderId: 'kecil',
      tierProviders: const {1: 'kecil'},
    );
    final s = Session(id: 's', channel: 't', userKey: 'u');
    final e = await r.explain('halo', s);
    expect(e['tier_providers'], containsPair('1', 'kecil'));
  });
}

import 'package:agent_core/agent_core.dart';
import 'package:agent_providers/agent_providers.dart';
import 'package:test/test.dart';

void main() {
  group('EmptyResponseGuard', () {
    test('satu attempt kosong → belum deterministik', () {
      final g = EmptyResponseGuard();
      g.recordAttempt(
        model: 'm',
        provider: 'p',
        finishReason: 'stop',
        usagePresent: true,
        zeroOutput: true,
        observedGeneration: false,
      );
      expect(g.deterministicEmpty, isFalse);
      expect(g.retryBudget(), 3);
    });

    test('dua usage-backed nol output dengan signature sama → deterministik',
        () {
      final g = EmptyResponseGuard();
      for (var i = 0; i < 2; i++) {
        g.recordAttempt(
          model: 'm',
          provider: 'p',
          finishReason: 'stop',
          usagePresent: true,
          zeroOutput: true,
          observedGeneration: false,
        );
      }
      expect(g.deterministicEmpty, isTrue);
    });

    test('signature berbeda → tidak deterministik (fail-open)', () {
      final g = EmptyResponseGuard();
      g.recordAttempt(
        model: 'm', provider: 'p', finishReason: 'stop',
        usagePresent: true, zeroOutput: true, observedGeneration: false,
      );
      g.recordAttempt(
        model: 'm', provider: 'p2', finishReason: 'stop',
        usagePresent: true, zeroOutput: true, observedGeneration: false,
      );
      expect(g.deterministicEmpty, isFalse);
    });

    test('bukti campuran → fail-open', () {
      final g = EmptyResponseGuard();
      g.recordAttempt(
        model: 'm', provider: 'p', finishReason: 'stop',
        usagePresent: true, zeroOutput: true, observedGeneration: false,
      );
      g.recordAttempt(
        model: 'm', provider: 'p', finishReason: 'stop',
        usagePresent: false, zeroOutput: false, observedGeneration: true,
      );
      expect(g.deterministicEmpty, isFalse);
    });

    test('biaya ≥ threshold → budget 3 menjadi 1', () {
      final g = EmptyResponseGuard();
      expect(g.retryBudget(lastAttemptCostUsd: 0.30), 1);
      expect(g.retryBudget(lastAttemptCostUsd: 0.25), 1);
      expect(g.retryBudget(lastAttemptCostUsd: 0.10), 3);
      expect(g.retryBudget(), 3);
    });

    test('disabled → perilaku legacy', () {
      final g = EmptyResponseGuard(
        settings: const EmptyGuardSettings(enabled: false),
      );
      for (var i = 0; i < 3; i++) {
        g.recordAttempt(
          model: 'm', provider: 'p', finishReason: 'stop',
          usagePresent: true, zeroOutput: true, observedGeneration: false,
        );
      }
      expect(g.deterministicEmpty, isFalse);
      expect(g.retryBudget(lastAttemptCostUsd: 10), 3);
    });

    test('streakCost terakumulasi; reset membersihkan', () {
      final g = EmptyResponseGuard();
      g.recordAttempt(
        model: 'm', provider: 'p', finishReason: 'stop',
        estimatedCostUsd: 0.4,
      );
      g.recordAttempt(
        model: 'm', provider: 'p', finishReason: 'stop',
        estimatedCostUsd: 0.1,
      );
      expect(g.streakCostUsd, closeTo(0.5, 1e-9));
      g.reset();
      expect(g.streakCostUsd, isNull);
      expect(g.attempts, 0);
    });
  });

  group('Repetition guard', () {
    test('teks pendek → fail-open', () {
      expect(isRepetitionDominated('halo dunia ini teks pendek ' * 5), isFalse);
    });

    test('teks periodik pendek (< ambang) → fail-open meski berulang', () {
      expect(isRepetitionDominated('abc ' * 90), isFalse,
          reason: 'di bawah minFragmentLength, tak dinilai');
    });

    test('jawaban normal panjang → false', () {
      final buf = StringBuffer();
      for (var i = 0; i < 400; i++) {
        buf.writeln('Paragraf $i berisi kalimat berbeda nomor $i.');
      }
      expect(isRepetitionDominated(buf.toString()), isFalse);
    });

    test('baris tunggal diulang ≥5x mencakup separuh → true', () {
      final line = 'x' * 120;
      final text = List.filled(6, line).join('\n');
      expect(isRepetitionDominated(text), isTrue);
    });

    test('jendela 60-char dengan counter/noise → window count dominan',
        () {
      final unit = StringBuffer('loop-marker-');
      unit.write('a' * 48);
      final text =
          List.generate(12, (i) => '${unit}#$i').join('\n');
      expect(text.length, greaterThan(minFragmentLength));
      expect(isRepetitionDominated(text), isTrue);
    });

    test('baris batch berbeda (mirip prefix) bukan runaway', () {
      final text = List.generate(20, (i) => 'INSERT INTO t VALUES ($i, '
          "'data-$i-panjang-yang-cukup-untuk-melewati-jendela-60-char');\n")
          .join();
      expect(isRunawayRepetition(text), isFalse);
    });

    test('isRunawayRepetition: dominasi + baris duplikat', () {
      final line = 'y' * 150;
      final text = List.filled(10, line).join('\n');
      expect(isRunawayRepetition(text), isTrue);
    });

    test('RunawayStreamWatch: belum ambang → false; loop panjang → true',
        () {
      final watch = RunawayStreamWatch();
      final line = "${'z' * 80} - unit verbatim sama tanpa counter";
      var fired = false;
      for (var i = 0; i < 300 && !fired; i++) {
        fired = watch.feed('$line\n');
      }
      expect(watch.charsSeen, greaterThan(stopPathMinChars));
      expect(fired, isTrue);
    });

    test('RunawayStreamWatch: baris bercounter (batch-like) → bukan runaway',
        () {
      final watch = RunawayStreamWatch();
      var fired = false;
      for (var i = 0; i < 500 && !fired; i++) {
        fired = watch.feed("${'z' * 80}-$i\n");
      }
      expect(fired, isFalse,
          reason: 'baris berbeda dengan prefix mirip = output batch sah');
    });

    test('RunawayStreamWatch: stream normal tidak pernah trigger', () {
      final watch = RunawayStreamWatch();
      var fired = false;
      for (var i = 0; i < 2000 && !fired; i++) {
        fired = watch.feed('Baris $i: konten unik yang cukup panjang.\n');
      }
      expect(fired, isFalse);
    });
  });

  group('Rate limit tracker', () {
    var now = 1000.0;
    double clock() => now;

    test('header lengkap terparse per jendela', () {
      final s = parseRateLimitHeaders(
        {
          'X-RateLimit-Limit-Requests': '60',
          'X-RateLimit-Remaining-Requests': '42',
          'X-Ratelimit-Reset-Requests': '12.5',
          'x-ratelimit-limit-tokens-1h': '100000',
          'x-ratelimit-remaining-tokens-1h': '80000',
          'x-ratelimit-reset-tokens-1h': '600',
        },
        provider: 'nous',
        clock: clock,
      );
      expect(s.hasData, isTrue);
      expect(s.requestsMin.limit, 60);
      expect(s.requestsMin.used, 18);
      expect(s.requestsMin.usagePct, closeTo(30.0, 0.01));
      expect(s.tokensHour.used, 20000);
      now = 1005.0;
      expect(s.requestsMin.remainingSecondsNow(clock: clock), closeTo(7.5, 0.01));
      expect(s.ageSeconds(clock: clock), 5.0);
    });

    test('header tidak ada → state kosong fail-open', () {
      final s = parseRateLimitHeaders(
        {'content-type': 'application/json'},
        provider: 'x',
        clock: clock,
      );
      expect(s.hasData, isFalse);
    });

    test('tracker menyimpan per provider dan memformat usage', () {
      final t = RateLimitTracker();
      t.update(parseRateLimitHeaders(
        {
          'x-ratelimit-limit-requests': '10',
          'x-ratelimit-remaining-requests': '9',
          'x-ratelimit-reset-requests': '30',
        },
        provider: 'portal',
        clock: clock,
      ));
      t.update(parseRateLimitHeaders(
        {'content-type': 'x'},
        provider: 'other',
        clock: clock,
      ));
      expect(t.stateFor('other'), isNull, reason: 'state kosong tidak disimpan');
      final lines = t.formatUsage(clock: clock);
      expect(lines.join('\n'), contains('portal: 1/10 req'));
      expect(lines.join('\n'), contains('reset 30s'));
      expect(t.stateFor('portal'), isNotNull);
    });
  });

  group('Side question', () {
    test('trimSnapshotForFork buang ekor sampai assistant text selesai', () {
      final history = [
        {'role': 'user', 'content': 'mulai'},
        {'role': 'assistant', 'content': 'selesai'},
        {'role': 'assistant', 'content': '', 'tool_calls': [
          {'function': {'name': 'shell'}}
        ]},
        {'role': 'tool', 'content': 'output'},
        {'role': 'user', 'content': 'in-flight'},
      ];
      final trimmed = trimSnapshotForFork(history);
      expect(trimmed.last['role'], 'assistant');
      expect(trimmed.last['content'], 'selesai');
    });

    test('render transcript: bias terbaru, budget, system dilewati', () {
      final history = [
        {'role': 'system', 'content': 'SYSTEM PROMPT RAHASIA'},
        {'role': 'user', 'content': 'halo'},
        {'role': 'assistant', 'content': 'hai!'},
        {'role': 'assistant', 'tool_calls': [
          {'function': {'name': 'shell'}}
        ]},
        {'role': 'tool', 'content': 'ls output'},
        {'role': 'user', 'content': 'thanks'},
      ];
      final t = renderHistoryForSideQuestion(history);
      expect(t, isNot(contains('RAHASIA')));
      expect(t, contains('USER: thanks'));
      expect(t, contains('ASSISTANT [called tools: shell]'));
      expect(t, contains('TOOL RESULT: ls output'));
      expect(t.indexOf('halo'), lessThan(t.indexOf('thanks')),
          reason: 'urutan kronologis dipertahankan');
    });

    test('budget terlampaui → pesan lama dihilangkan dengan penanda', () {
      final history = [
        for (var i = 0; i < 30; i++) ...[
          {'role': 'user', 'content': 'pesan panjang nomor $i ' * 20},
          {'role': 'assistant', 'content': 'jawaban $i ' * 20},
        ],
      ];
      final t = renderHistoryForSideQuestion(history, charBudget: 2000);
      expect(t.startsWith('[...older conversation omitted...]'), isTrue);
      expect(t.length, lessThan(2400));
    });

    test('pesan terlalu panjang dipangkas per pesan', () {
      final history = [
        {'role': 'user', 'content': 'x' * 5000},
      ];
      final t = renderHistoryForSideQuestion(history);
      expect(t, contains('…'));
      expect(t.length, lessThan(2400));
    });

    test('history kosong → placeholder', () {
      expect(renderHistoryForSideQuestion(const []), '(no prior conversation)');
    });

    test('prompt builder menyusun transcript + pertanyaan', () {
      final p = buildSideQuestionPrompt(
        transcript: 'USER: hai',
        question: 'apa isi percakapan?',
      );
      expect(p, contains('USER: hai'));
      expect(p, contains('SIDE QUESTION: apa isi percakapan?'));
      expect(p, contains('Do NOT call any tools'));
    });
  });

  group('Wiring agent loop — empty guard', () {
    test('jawaban kosong di-retry lalu sukses pada attempt kedua', () async {
      final replies = <String>[];
      final provider = _ScriptedLlm([
        _ScriptedTurn(text: '', finish: 'stop'),
        _ScriptedTurn(text: 'jawaban asli', finish: 'stop'),
      ]);
      final router = Router(
        providers: {'mock': provider},
        defaultProviderId: 'mock',
      );
      final loop = AgentLoop(
        router: router,
        contextBuilder: ContextBuilder(),
        compactor: Compactor(),
        gate: AllowAllGate(),
        executor: MockToolExecutor(),
        memory: NoopMemory(),
        reply: (m, text) async => replies.add(text),
      );
      await loop.handle(
        InboundMessage(
          channel: 'cli', userKey: 'u1', sessionKey: 'cli:u1', text: 'halo',
        ),
        Session(id: 's', channel: 'cli', userKey: 'u1'),
      );
      expect(provider.turns, 2);
      expect(replies.last, contains('jawaban asli'));
      expect(loop.lastTurnEndReason, 'completed');
    });

    test('kosong deterministik → berhenti cepat, tidak retry penuh',
        () async {
      final replies = <String>[];
      final provider = _ScriptedLlm([
        _ScriptedTurn(text: '', finish: 'stop', usage: const TokenUsage(prompt: 100, completion: 0, total: 100)),
        _ScriptedTurn(text: '', finish: 'stop', usage: const TokenUsage(prompt: 100, completion: 0, total: 100)),
      ]);
      final router = Router(
        providers: {'mock': provider},
        defaultProviderId: 'mock',
      );
      final loop = AgentLoop(
        router: router,
        contextBuilder: ContextBuilder(),
        compactor: Compactor(),
        gate: AllowAllGate(),
        executor: MockToolExecutor(),
        memory: NoopMemory(),
        reply: (m, text) async => replies.add(text),
      );
      await loop.handle(
        InboundMessage(
          channel: 'cli', userKey: 'u1', sessionKey: 'cli:u1', text: 'halo',
        ),
        Session(id: 's', channel: 'cli', userKey: 'u1'),
      );
      expect(provider.turns, 2,
          reason: 'deterministic empty: berhenti tanpa menghabiskan budget 3');
      expect(replies.last, contains('(tidak ada jawaban)'));
      expect(loop.lastTurnEndReason, 'no_answer');
    });
  });
}

class _ScriptedTurn {
  _ScriptedTurn({required this.text, required this.finish, this.usage});
  final String text;
  final String finish;
  final TokenUsage? usage;
}

class _ScriptedLlm implements LlmProvider {
  _ScriptedLlm(List<_ScriptedTurn> script) : _script = script;
  final List<_ScriptedTurn> _script;
  int turns = 0;

  @override
  String get id => 'mock';

  @override
  Capabilities get capabilities => const Capabilities(toolCalling: false);

  @override
  Stream<LlmEvent> chat(ChatRequest request) async* {
    final t = turns < _script.length ? _script[turns] : _script.last;
    turns++;
    if (t.text.isNotEmpty) yield LlmTextDelta(t.text);
    if (t.usage != null) yield LlmUsage(t.usage!);
    yield LlmDone(finishReason: t.finish);
  }

  @override
  Future<List<double>> embed(String text) async => const [];
}

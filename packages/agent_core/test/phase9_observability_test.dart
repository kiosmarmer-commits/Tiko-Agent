// Hermes fase-9 observability (C5–C7): usage anchor, image token cost,
// account usage cache, dan wiring preflight/loop.
import 'dart:async';
import 'dart:io';

import 'package:agent_core/agent_core.dart';
import 'package:agent_providers/agent_providers.dart';
import 'package:test/test.dart';

void main() {
  group('UsageAnchor (Hermes usage_anchor)', () {
    test('capture + matches: prefix tumbuh dengan append tetap cocok', () {
      final m1 = const ChatMessage(role: 'user', content: 'halo');
      final anchor = UsageAnchor.capture(500, 30, [m1]);
      expect(anchor, isNotNull);
      expect(anchor!.promptTokens, 500);
      expect(anchor.completionTokens, 30);
      expect(anchor.baseCount, 1);
      // Prefix sama + balasan assistant ditambahkan → tetap cocok.
      final grown = [
        m1,
        const ChatMessage(role: 'assistant', content: 'respons'),
      ];
      expect(anchor.matches(grown), isTrue);
      // Prefix ditulis-ulang (kompresi) → gagal-closed.
      final rewritten = [
        const ChatMessage(role: 'user', content: 'ringkasan'),
        const ChatMessage(role: 'assistant', content: 'respons'),
      ];
      expect(anchor.matches(rewritten), isFalse);
    });

    test('capture menolak usage tidak valid', () {
      final m1 = const ChatMessage(role: 'user', content: 'halo');
      expect(UsageAnchor.capture(0, 10, [m1]), isNull);
      expect(UsageAnchor.capture(-5, 10, [m1]), isNull);
      expect(UsageAnchor.capture(100, 10, const []), isNull);
    });

    test('anchoredContextTokens: usage nyata + delta (skip assistant)',
        () {
      final m1 = ChatMessage(role: 'user', content: 'x' * 400);
      final anchor = UsageAnchor.capture(500, 30, [m1])!;
      // Delta: assistant (skip — sudah di completion) + tool result 1000 char.
      final grown = [
        m1,
        const ChatMessage(
          role: 'assistant',
          content: '',
          toolCalls: [
            ToolCall(id: 't1', name: 'datetime', args: {}),
          ],
        ),
        ChatMessage(role: 'tool', content: 'y' * 1000, toolCallId: 't1'),
      ];
      // 500 + 30 + (1000 ~/ 4) = 780; tool result tanpa gambar.
      expect(anchor.anchoredContextTokens(grown), 780);
      // Anchor basah terhadap transcript lain → null (fail-closed).
      final other = [
        const ChatMessage(role: 'user', content: 'ganti'),
      ];
      expect(anchor.anchoredContextTokens(other), isNull);
    });

    test('fingerprint stabil dan peka terhadap konten/toolCalls', () {
      final a = const ChatMessage(role: 'user', content: 'halo');
      final b = const ChatMessage(role: 'user', content: 'halo');
      final c = const ChatMessage(role: 'user', content: 'halo!');
      expect(chatMessageFingerprint(a), chatMessageFingerprint(b));
      expect(chatMessageFingerprint(a), isNot(chatMessageFingerprint(c)));
      final withCall = const ChatMessage(
        role: 'assistant',
        content: '',
        toolCalls: [ToolCall(id: 't1', name: 'calc', args: {'a': 1})],
      );
      final withCall2 = const ChatMessage(
        role: 'assistant',
        content: '',
        toolCalls: [ToolCall(id: 't1', name: 'calc', args: {'a': 2})],
      );
      expect(
        chatMessageFingerprint(withCall),
        isNot(chatMessageFingerprint(withCall2)),
      );
    });

    test('toJson/fromJson roundtrip; fromJson ketat pada data korup', () {
      final m1 = const ChatMessage(role: 'user', content: 'halo');
      final anchor = UsageAnchor.capture(500, 30, [m1])!;
      final back = UsageAnchor.fromJson(anchor.toJson());
      expect(back, isNotNull);
      expect(back!.promptTokens, 500);
      expect(back.matches([m1]), isTrue);
      expect(UsageAnchor.fromJson(null), isNull);
      expect(UsageAnchor.fromJson('bukan-map'), isNull);
      expect(UsageAnchor.fromJson({'prompt_tokens': 0}), isNull);
      expect(
        UsageAnchor.fromJson({
          'prompt_tokens': 10,
          'base_count': 1,
          'base_last_fp': '',
          'base_prefix_fp': 'x',
        }),
        isNull,
      );
    });

    test('UsageAnchorStore: roundtrip, hapus, korup, sanitasi id', () async {
      final dir =
          await Directory.systemTemp.createTemp('tiko_anchor_test');
      try {
        final store = UsageAnchorStore(dir.path);
        final m1 = const ChatMessage(role: 'user', content: 'halo');
        final anchor = UsageAnchor.capture(500, 30, [m1])!;
        store.save('s1', anchor);
        final loaded = store.load('s1');
        expect(loaded, isNotNull);
        expect(loaded!.matches([m1]), isTrue);
        store.save('s1', null);
        expect(store.load('s1'), isNull);
        // Id sesi dengan karakter liar disanitasi tetap bisa di-load.
        store.save('cli:u1/sesi aneh', anchor);
        expect(store.load('cli:u1/sesi aneh'), isNotNull);
        // File korup → null (fail-closed), tidak throw.
        final safeId = 'korup';
        File('${dir.path}/$safeId.json').writeAsStringSync('{bukan json');
        expect(store.load(safeId), isNull);
      } finally {
        await dir.delete(recursive: true);
      }
    });
  });

  group('ImageTokenCostStore (Hermes image_token_cost)', () {
    test('kalibrasi residu: perImage dari usage nyata - teks saja', () {
      final m1 = ChatMessage(role: 'user', content: 'x' * 400);
      final anchor = UsageAnchor.capture(1000, 50, [m1]);
      final store = ImageTokenCostStore();
      // Delta memperkenalkan 2 gambar pada pesan user baru (400 char).
      final messages = [
        m1,
        ChatMessage(
          role: 'user',
          content: 'y' * 400,
          images: [ChatImage(base64: 'a'), ChatImage(base64: 'b')],
        ),
      ];
      // teks saja = 1000 + 50 + 100 = 1150; real = 1150 + 2*1000.
      final learned = store.calibrateFromUsage(
        model: 'gpt-4o',
        promptTokens: 3150,
        anchor: anchor,
        messages: messages,
      );
      expect(learned, 1000);
      expect(store.learnedFor('gpt-4o'), 1000);
      // Model lain masih default.
      expect(store.learnedFor('claude-haiku'), defaultImageTokenCost);
    });

    test('EMA: observasi berikutnya dicampur dengan nilai prior', () {
      final m1 = ChatMessage(role: 'user', content: 'x' * 400);
      final anchor = UsageAnchor.capture(1000, 50, [m1]);
      final store = ImageTokenCostStore();
      final withImages = [
        m1,
        ChatMessage(
          role: 'user',
          content: 'y' * 400,
          images: [ChatImage(base64: 'a')],
        ),
      ];
      // Observasi 1: teks=1150, real=2150 → perImage=1000.
      store.calibrateFromUsage(
        model: 'm',
        promptTokens: 2150,
        anchor: anchor,
        messages: withImages,
      );
      // Observasi 2: real=3150 → perImage=2000; EMA 0.5 → 1500.
      final learned2 = store.calibrateFromUsage(
        model: 'm',
        promptTokens: 3150,
        anchor: anchor,
        messages: withImages,
      );
      expect(learned2, 1500);
    });

    test('residu tidak masuk akal / tanpa gambar / anchor basah → null', () {
      final m1 = ChatMessage(role: 'user', content: 'x' * 400);
      final anchor = UsageAnchor.capture(1000, 50, [m1]);
      final store = ImageTokenCostStore();
      final withImages = [
        m1,
        ChatMessage(
          role: 'user',
          content: 'y' * 400,
          images: [ChatImage(base64: 'a')],
        ),
      ];
      // perImage = (1151 - 1150) = 1 < 64 → null.
      expect(
        store.calibrateFromUsage(
          model: 'm',
          promptTokens: 1151,
          anchor: anchor,
          messages: withImages,
        ),
        isNull,
      );
      // Tanpa gambar di delta → null.
      expect(
        store.calibrateFromUsage(
          model: 'm',
          promptTokens: 3150,
          anchor: anchor,
          messages: [m1],
        ),
        isNull,
      );
      // Anchor basah → null.
      expect(
        store.calibrateFromUsage(
          model: 'm',
          promptTokens: 3150,
          anchor: anchor,
          messages: [
            const ChatMessage(role: 'user', content: 'ditulis-ulang'),
          ],
        ),
        isNull,
      );
    });

    test('persist atomik: store baru membaca tabel yang dipelajari',
        () async {
      final dir =
          await Directory.systemTemp.createTemp('tiko_imgcost_test');
      try {
        final path = '${dir.path}/cache/image_token_costs.json';
        final m1 = ChatMessage(role: 'user', content: 'x' * 400);
        final anchor = UsageAnchor.capture(1000, 50, [m1]);
        final store = ImageTokenCostStore(path: path);
        store.calibrateFromUsage(
          model: 'gpt-4o',
          promptTokens: 2150,
          anchor: anchor,
          messages: [
            m1,
            ChatMessage(
              role: 'user',
              content: 'y' * 400,
              images: [ChatImage(base64: 'a')],
            ),
          ],
        );
        final reloaded = ImageTokenCostStore(path: path);
        expect(reloaded.learnedFor('gpt-4o'), 1000);
      } finally {
        await dir.delete(recursive: true);
      }
    });

    test('countImages menghitung gambar lintas pesan', () {
      expect(
        countImages([
          const ChatMessage(role: 'user', content: 'a'),
          const ChatMessage(role: 'user', content: 'b', images: [
            ChatImage(base64: '1'),
            ChatImage(base64: '2'),
          ]),
          const ChatMessage(role: 'user', content: 'c', images: [
            ChatImage(base64: '3'),
          ]),
        ]),
        3,
      );
    });
  });

  group('AccountUsageCache (Hermes account_usage_cache)', () {
    test('snapshot tanpa window tidak pernah disimpan', () {
      final cache = AccountUsageCache();
      final empty = AccountUsageSnapshot(
        provider: 'openai',
        source: 'api',
        fetchedAt: DateTime.now(),
      );
      cache.remember('openai', empty);
      expect(cache.cached('openai'), isNull);
      final withWindows = AccountUsageSnapshot(
        provider: 'openai',
        source: 'api',
        fetchedAt: DateTime.now(),
        windows: [
          const AccountUsageWindow(label: 'harian', usedPercent: 42.5),
        ],
      );
      cache.remember('openai', withWindows);
      expect(cache.cached('openai'), same(withWindows));
    });

    test('late-fetch guard: fetch yang mulai lebih dulu tidak menang', () {
      final cache = AccountUsageCache();
      final fresh = AccountUsageSnapshot(
        provider: 'p',
        source: 'api',
        fetchedAt: DateTime.now(),
        windows: [
          const AccountUsageWindow(label: 'w', usedPercent: 10),
        ],
      );
      final older = AccountUsageSnapshot(
        provider: 'p',
        source: 'api',
        fetchedAt: DateTime.now(),
        windows: [
          const AccountUsageWindow(label: 'w', usedPercent: 90),
        ],
      );
      cache.remember('p', fresh, startedMonotonic: 200);
      cache.remember('p', older, startedMonotonic: 100);
      expect(cache.cached('p')!.windows.first.usedPercent, 10);
      // Fetch yang mulai setelahnya tetap menang.
      final newer = AccountUsageSnapshot(
        provider: 'p',
        source: 'api',
        fetchedAt: DateTime.now(),
        windows: [
          const AccountUsageWindow(label: 'w', usedPercent: 30),
        ],
      );
      cache.remember('p', newer, startedMonotonic: 300);
      expect(cache.cached('p')!.windows.first.usedPercent, 30);
    });

    test('slot identitas: fetch per-kredensial tidak mencemari slot wide',
        () {
      final cache = AccountUsageCache();
      final snap = AccountUsageSnapshot(
        provider: 'p',
        source: 'api',
        fetchedAt: DateTime.now(),
        identity: 'akun-1',
        windows: [
          const AccountUsageWindow(label: 'w', usedPercent: 55),
        ],
      );
      cache.remember('p', snap, identityId: 'cred-1');
      expect(cache.cached('p'), isNull);
      expect(cache.cached('p', identityId: 'akun-1'), same(snap));
      // Fetch per-turn (tanpa identityId) mengisi slot wide + slot identitas.
      cache.remember('p', snap);
      expect(cache.cached('p'), same(snap));
      expect(cache.cached('p', identityId: 'akun-1'), same(snap));
    });

    test('snapshotIsStale: fresh ok, >15 menit basah, umur negatif basah',
        () {
      final cache = AccountUsageCache();
      final now = DateTime.now();
      final fresh = AccountUsageSnapshot(
        provider: 'p',
        source: 'api',
        fetchedAt: now.subtract(const Duration(minutes: 2)),
        windows: [const AccountUsageWindow(label: 'w', usedPercent: 1)],
      );
      expect(cache.snapshotIsStale(fresh, now: now), isFalse);
      final old = AccountUsageSnapshot(
        provider: 'p',
        source: 'api',
        fetchedAt: now.subtract(const Duration(minutes: 16)),
        windows: [const AccountUsageWindow(label: 'w', usedPercent: 1)],
      );
      expect(cache.snapshotIsStale(old, now: now), isTrue);
      final future = AccountUsageSnapshot(
        provider: 'p',
        source: 'api',
        fetchedAt: now.add(const Duration(minutes: 5)),
        windows: [const AccountUsageWindow(label: 'w', usedPercent: 1)],
      );
      expect(cache.snapshotIsStale(future, now: now), isTrue);
      expect(cache.snapshotIsStale(null, now: now), isTrue);
    });

    test('refreshIfDue: throttle, inflight guard, dan fetcher gagal',
        () async {
      final cache = AccountUsageCache();
      var calls = 0;
      Future<AccountUsageSnapshot?> fetcher(String provider) async {
        calls++;
        if (calls == 1) {
          return AccountUsageSnapshot(
            provider: provider,
            source: 'api',
            fetchedAt: DateTime.now(),
            windows: [
              const AccountUsageWindow(label: 'w', usedPercent: 12),
            ],
          );
        }
        throw Exception('provider down');
      }

      cache.registerFetcher('p', fetcher);
      var now = 1000.0;
      await cache.refreshIfDue('p', now: () => now);
      expect(calls, 1);
      expect(cache.cached('p')!.windows.first.usedPercent, 12);
      // Masih dalam REFRESH_AFTER_S → tidak di-fetch ulang.
      now = 1050.0;
      await cache.refreshIfDue('p', now: () => now);
      expect(calls, 1);
      // Setelah jatuh tempo: fetcher gagal → snapshot lama dipertahankan,
      // kegagalan tetap dihitung sebagai percobaan.
      now = 1200.0;
      await cache.refreshIfDue('p', now: () => now);
      expect(calls, 2);
      expect(cache.cached('p')!.windows.first.usedPercent, 12);
      now = 1210.0;
      await cache.refreshIfDue('p', now: () => now);
      expect(calls, 2);
      // Tanpa fetcher terdaftar → no-op.
      await cache.refreshIfDue('tanpa-fetcher', now: () => 9999);
    });

    test('toJson/fromJson snapshot roundtrip', () {
      final snap = AccountUsageSnapshot(
        provider: 'openai',
        source: 'api',
        fetchedAt: DateTime.parse('2026-02-01T10:00:00Z'),
        plan: 'plus',
        windows: [
          const AccountUsageWindow(
            label: 'mingguan',
            usedPercent: 70,
            scope: 'model',
          ),
        ],
        details: ['catatan'],
      );
      final back = AccountUsageSnapshot.fromJson(snap.toJson());
      expect(back, isNotNull);
      expect(back!.provider, 'openai');
      expect(back.plan, 'plus');
      expect(back.windows.single.label, 'mingguan');
      expect(back.windows.single.scope, 'model');
      expect(back.available, isTrue);
    });
  });

  group('formatAccountUsageLines (rendering /usage)', () {
    test('fresh, usang, dan unavailable dirender jujur', () {
      final now = DateTime.now();
      final fresh = AccountUsageSnapshot(
        provider: 'openai',
        source: 'api',
        fetchedAt: now.subtract(const Duration(minutes: 1)),
        windows: [
          const AccountUsageWindow(label: 'harian', usedPercent: 42.55),
          const AccountUsageWindow(label: 'opus', usedPercent: 10, scope: 'model'),
        ],
      );
      final stale = AccountUsageSnapshot(
        provider: 'anthropic',
        source: 'api',
        fetchedAt: now.subtract(const Duration(hours: 1)),
        windows: [
          const AccountUsageWindow(label: 'mingguan', usedPercent: 90),
        ],
      );
      final unavailable = AccountUsageSnapshot(
        provider: 'ollama',
        source: 'api',
        fetchedAt: now,
        unavailableReason: 'provider lokal tanpa API usage',
      );
      final lines = formatAccountUsageLines(
        [fresh, stale, unavailable],
        now: now,
        isStale: (s) => s == stale,
      );
      final joined = lines.join('\n');
      expect(joined, contains('openai (api)'));
      expect(joined, contains('42.5%'));
      expect(joined, contains('[model]'));
      expect(joined, contains('anthropic (api, usang — tidak diketahui)'));
      expect(joined, contains('ollama: tidak tersedia (provider lokal'));
    });
  });

  group('PreflightGate anchored (C5+C7 wiring)', () {
    AgentContext _ctx(
      List<ChatMessage> messages, {
      String system = '',
    }) {
      return AgentContext(
        messages: messages,
        tools: const [],
        session: Session(id: 's', channel: 'cli', userKey: 'u1'),
        systemPrompt: system,
      );
    }

    test('tekanan anchored menggantikan heuristik bila anchor fresh', () async {
      final m1 = ChatMessage(role: 'user', content: 'x' * 400);
      final gate = PreflightGate();
      gate.usageAnchor = UsageAnchor.capture(500, 30, [m1]);
      final ctx = _ctx([m1]);
      final verdict = await gate.run(
        ctx,
        compactor: Compactor(enabled: false),
      );
      // request = [user(400)] → anchored = 500 + 30 = 530.
      expect(verdict.anchored, isTrue);
      expect(verdict.pressure, 530);
    });

    test('anchor basah → heuristik penuh (fail-closed)', () async {
      final gate = PreflightGate();
      gate.usageAnchor = UsageAnchor.capture(
        500,
        30,
        [const ChatMessage(role: 'user', content: 'transcript lama')],
      );
      final ctx = _ctx([const ChatMessage(role: 'user', content: 'baru')]);
      final verdict = await gate.run(
        ctx,
        compactor: Compactor(enabled: false),
      );
      expect(verdict.anchored, isFalse);
      // Heuristik: 4 char ~/4 = 1 token.
      expect(verdict.pressure, 1);
    });

    test('gambar dihargai imageCost pada heuristik', () {
      final img = const ChatMessage(
        role: 'user',
        content: 'x',
        images: [ChatImage(base64: 'a'), ChatImage(base64: 'b')],
      );
      final plain = const ChatMessage(role: 'user', content: 'x');
      final withImages = PreflightGate.estimatePressureTokens(
        _CtxBuilder.ctx([img]),
        imageCost: 1500,
      );
      final without = PreflightGate.estimatePressureTokens(
        _CtxBuilder.ctx([plain]),
        imageCost: 1500,
      );
      // 2 gambar × 1500 token × 4 char/token = 12.000 char tambahan.
      expect(withImages - without, 2 * 1500);
    });
  });

  group('AgentLoop wiring fase-9', () {
    test('anchor dicapture dari LlmUsage dan dipersist per sesi', () async {
      final dir =
          await Directory.systemTemp.createTemp('tiko_phase9_loop');
      try {
        final provider = _UsageLlm();
        final replies = <String>[];
        final loop = AgentLoop(
          router: Router(
            providers: {'u': provider},
            defaultProviderId: 'u',
          ),
          contextBuilder: ContextBuilder(),
          compactor: Compactor(),
          gate: AllowAllGate(),
          executor: MockToolExecutor(),
          memory: NoopMemory(),
          reply: (m, text) async => replies.add(text),
          usageAnchorStore: UsageAnchorStore('${dir.path}/anchors'),
          imageTokenCosts: ImageTokenCostStore(),
        );
        final session = Session(id: 's9', channel: 'cli', userKey: 'u1');
        await loop.handle(
          const InboundMessage(
            channel: 'cli',
            userKey: 'u1',
            sessionKey: 'cli:u1',
            text: 'kerjakan',
          ),
          session,
        );
        expect(provider.callCount, 2, reason: '1 tool call lalu jawaban akhir');
        expect(loop.usageAnchor, isNotNull);
        expect(loop.usageAnchor!.promptTokens, 1200,
            reason: 'anchor terakhir = request terakhir yang terhargai');
        // Persist per sesi: anchor tersimpan di disk dan valid terhadap
        // request transcript terakhir.
        final saved = UsageAnchorStore('${dir.path}/anchors').load('s9');
        expect(saved, isNotNull);
        expect(saved!.matches(provider.requests.last.messages), isTrue);
        // Request kedua dalam turn yang sama ber-anchoring (prefix tumbuh
        // dengan append tool result).
        expect(loop.lastAnchoredPressureTokens, isNotNull);
      } finally {
        await dir.delete(recursive: true);
      }
    });

    test('tanpa usage dari provider: anchor lama dipertahankan, turn aman',
        () async {
      final replies = <String>[];
      final loop = AgentLoop(
        router: Router(
          providers: {'e': _EchoLlm('e')},
          defaultProviderId: 'e',
        ),
        contextBuilder: ContextBuilder(),
        compactor: Compactor(),
        gate: AllowAllGate(),
        executor: MockToolExecutor(),
        memory: NoopMemory(),
        reply: (m, text) async => replies.add(text),
      );
      final session = Session(id: 's', channel: 'cli', userKey: 'u1');
      await loop.handle(
        const InboundMessage(
          channel: 'cli',
          userKey: 'u1',
          sessionKey: 'cli:u1',
          text: 'halo',
        ),
        session,
      );
      expect(loop.usageAnchor, isNull);
      expect(loop.lastAnchoredPressureTokens, isNull);
      expect(replies, isNotEmpty);
    });
  });
}

/// Helper kecil membangun AgentContext di grup statis.
class _CtxBuilder {
  static AgentContext ctx(List<ChatMessage> messages) => AgentContext(
        messages: messages,
        tools: const [],
        session: Session(id: 's', channel: 'cli', userKey: 'u1'),
      );
}

/// Provider scripted: request pertama memancarkan tool call + usage nyata
/// (800 prompt / 100 completion), request kedua jawaban akhir + usage.
class _UsageLlm implements LlmProvider {
  int callCount = 0;
  final requests = <ChatRequest>[];

  @override
  String get id => 'u';

  @override
  Capabilities get capabilities => const Capabilities(toolCalling: true);

  @override
  Stream<LlmEvent> chat(ChatRequest req) async* {
    requests.add(req);
    callCount++;
    if (callCount == 1) {
      yield const LlmTextDelta('mengerjakan');
      yield const LlmToolCall(
        ToolCall(id: 'c1', name: 'datetime', args: {}),
      );
      yield const LlmUsage(TokenUsage(prompt: 800, completion: 100));
      yield const LlmDone(finishReason: 'tool_calls');
      return;
    }
    yield const LlmTextDelta('selesai');
    yield const LlmUsage(TokenUsage(prompt: 1200, completion: 20));
    yield const LlmDone(finishReason: 'stop');
  }

  @override
  Future<List<double>> embed(String text) async => const [];
}

/// Provider echo tanpa usage — dipakai test fail-closed.
class _EchoLlm implements LlmProvider {
  _EchoLlm(this.id);

  @override
  final String id;

  final String text = 'mock';

  @override
  Capabilities get capabilities => const Capabilities(toolCalling: false);

  @override
  Stream<LlmEvent> chat(ChatRequest req) async* {
    yield LlmTextDelta(text);
    yield const LlmDone(finishReason: 'stop');
  }

  @override
  Future<List<double>> embed(String text) async => const [];
}

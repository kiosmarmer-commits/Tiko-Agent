import 'package:agent_core/agent_core.dart';
import 'package:agent_memory/agent_memory.dart';
import 'package:test/test.dart';
import 'package:tiko_runtime/tiko_runtime.dart';

class _ScriptedLlm implements LlmProvider {
  _ScriptedLlm(this.response);

  final String response;
  int calls = 0;

  @override
  String get id => 'scripted-consolidator';

  @override
  Capabilities get capabilities =>
      const Capabilities(toolCalling: false, streaming: true, maxContext: 8192);

  @override
  Stream<LlmEvent> chat(ChatRequest req) async* {
    calls++;
    yield LlmTextDelta(response);
  }

  @override
  Future<List<double>> embed(String text) async => const [];
}

class _ErrorLlm implements LlmProvider {
  const _ErrorLlm();

  @override
  String get id => 'error-consolidator';

  @override
  Capabilities get capabilities =>
      const Capabilities(toolCalling: false, streaming: true, maxContext: 8192);

  @override
  Stream<LlmEvent> chat(ChatRequest req) async* {
    yield const LlmError('provider mati');
  }

  @override
  Future<List<double>> embed(String text) async => const [];
}

void main() {
  final old = DateTime.utc(2026, 11, 1); // ~16 hari lalu -> retensi rendah
  final now = DateTime.utc(2026, 11, 17);

  /// Memory dengan [n] entri episodik lama (retensi rendah, half-life 14h).
  LayeredMemory memoryWithOldEpisodes(int n, {double importance = 0.5}) {
    final m = LayeredMemory();
    for (var i = 0; i < n; i++) {
      m.add(
        MemoryLayerType.episodic,
        'Catatan sesi ke-$i: pengguna meminta laporan penjualan mingguan.',
        importance: importance,
        now: old,
      );
    }
    return m;
  }

  const cfg = IdleConsolidationConfig(
    enabled: true,
    idleTurns: 2,
    minCandidates: 3,
    maxEntriesPerBatch: 10,
    maxSummariesPerDay: 2,
    maxOutputFacts: 4,
  );

  test('E2: entri episodik retensi rendah dikonsolidasi jadi fakta semantik',
      () async {
    final memory = memoryWithOldEpisodes(5);
    final llm = _ScriptedLlm('- Pengguna rutin meminta laporan penjualan.\n'
        '- Sesi berisi permintaan laporan mingguan.\n');
    final events = <String>[];
    final c = IdleMemoryConsolidator(
      memory: memory,
      llm: llm,
      config: cfg,
      onEvent: (type, _) => events.add(type),
    );

    final report = await c.maybeConsolidate(now: now);
    expect(report, isNotNull);
    expect(report!.candidates, 5);
    expect(report.factsAdded, 2);
    expect(llm.calls, 1);
    expect(memory.countLayer(MemoryLayerType.semantic), 2);
    // Entri asli TIDAK dihapus, hanya ditandai consolidated.
    expect(memory.countLayer(MemoryLayerType.episodic), 5);
    expect(
      memory.all.every((e) =>
          e.layer != MemoryLayerType.episodic || e.consolidated),
      isTrue,
    );
    expect(events, contains('memory.idle_consolidated'));
  });

  test('E2: kandidat di bawah minimum -> tanpa panggilan LLM', () async {
    final memory = memoryWithOldEpisodes(2);
    final llm = _ScriptedLlm('- fakta\n');
    final c = IdleMemoryConsolidator(
      memory: memory,
      llm: llm,
      config: cfg,
    );
    final report = await c.maybeConsolidate(now: now);
    expect(report, isNull);
    expect(llm.calls, 0);
  });

  test('E2: entri retensi tinggi (baru) bukan kandidat', () async {
    final memory = LayeredMemory();
    for (var i = 0; i < 5; i++) {
      memory.add(
        MemoryLayerType.episodic,
        'Catatan baru ke-$i.',
        now: now, // retensi 1.0 -> bukan kandidat
      );
    }
    final llm = _ScriptedLlm('- fakta\n');
    final c = IdleMemoryConsolidator(
      memory: memory,
      llm: llm,
      config: cfg,
    );
    expect(await c.maybeConsolidate(now: now), isNull);
    expect(llm.calls, 0);
  });

  test('E2: jawaban NONE -> tidak ada perubahan memori', () async {
    final memory = memoryWithOldEpisodes(5);
    final llm = _ScriptedLlm('NONE');
    final c = IdleMemoryConsolidator(
      memory: memory,
      llm: llm,
      config: cfg,
    );
    expect(await c.maybeConsolidate(now: now), isNull);
    expect(memory.countLayer(MemoryLayerType.semantic), 0);
    expect(
      memory.all.any((e) => e.layer == MemoryLayerType.episodic && !e.consolidated),
      isTrue,
      reason: 'tanpa fakta valid, entri asli tidak ditandai',
    );
  });

  test('E2: LLM error -> event error, tanpa perubahan memori', () async {
    final memory = memoryWithOldEpisodes(5);
    final events = <String>[];
    final c = IdleMemoryConsolidator(
      memory: memory,
      llm: const _ErrorLlm(),
      config: cfg,
      onEvent: (type, _) => events.add(type),
    );
    expect(await c.maybeConsolidate(now: now), isNull);
    expect(events, contains('memory.idle_consolidation_error'));
    expect(memory.countLayer(MemoryLayerType.semantic), 0);
  });

  test('E2: cap harian membatasi panggilan LLM', () async {
    final memory = memoryWithOldEpisodes(5);
    final llm = _ScriptedLlm('- fakta padat\n');
    final c = IdleMemoryConsolidator(
      memory: memory,
      llm: llm,
      config: cfg, // maxSummariesPerDay = 2
    );
    // Pass pertama: 5 kandidat -> konsolidasi, tandai consolidated.
    expect(await c.maybeConsolidate(now: now), isNotNull);
    // Tambah kandidat baru untuk pass berikutnya.
    for (var i = 0; i < 5; i++) {
      memory.add(
        MemoryLayerType.episodic,
        'Kandidat baru ke-$i.',
        now: old,
      );
    }
    expect(await c.maybeConsolidate(now: now), isNotNull);
    // Tambah lagi -> cap habis.
    for (var i = 0; i < 5; i++) {
      memory.add(
        MemoryLayerType.episodic,
        'Kandidat ketiga ke-$i.',
        now: old,
      );
    }
    expect(await c.maybeConsolidate(now: now), isNull);
    expect(llm.calls, 2);
  });

  test('E2: gate idle turn — noteTurn baru memicu di ambang', () async {
    final memory = memoryWithOldEpisodes(5);
    final llm = _ScriptedLlm('- fakta\n');
    final c = IdleMemoryConsolidator(
      memory: memory,
      llm: llm,
      config: cfg, // idleTurns = 2
    );
    expect(await c.noteTurn(now: now), isNull); // giliran 1
    expect(llm.calls, 0);
    final report = await c.noteTurn(now: now); // giliran 2 -> jalan
    expect(report, isNotNull);
    expect(llm.calls, 1);
  });

  test('E2: parsing fail-closed — baris tak valid dibuang, cap fakta', () async {
    final memory = memoryWithOldEpisodes(5);
    final llm = _ScriptedLlm(
      'Berikut analisisnya:\n'
      '- fakta valid satu\n'
      '\n'
      '- fakta valid dua\n'
      'baris tanpa bullet dibuang\n'
      '- \n'
      '- ${'x' * 301}\n'
      '- fakta valid tiga\n'
      '- fakta valid empat\n'
      '- fakta valid lima (dibuang, cap 4)\n',
    );
    final c = IdleMemoryConsolidator(
      memory: memory,
      llm: llm,
      config: cfg, // maxOutputFacts = 4
    );
    final report = await c.maybeConsolidate(now: now);
    expect(report, isNotNull);
    expect(report!.factsAdded, 4);
    expect(memory.countLayer(MemoryLayerType.semantic), 4);
  });

  test('E2: batch dibatasi maxEntriesPerBatch (terlama dulu)', () async {
    final memory = memoryWithOldEpisodes(15);
    final llm = _ScriptedLlm('- fakta\n');
    final c = IdleMemoryConsolidator(
      memory: memory,
      llm: llm,
      config: const IdleConsolidationConfig(
        enabled: true,
        idleTurns: 2,
        minCandidates: 3,
        maxEntriesPerBatch: 10,
        maxSummariesPerDay: 2,
      ),
    );
    final report = await c.maybeConsolidate(now: now);
    expect(report!.candidates, 10);
    // 5 entri termuda tetap belum terkonsolidasi.
    expect(
      memory.all
          .where((e) =>
              e.layer == MemoryLayerType.episodic && !e.consolidated)
          .length,
      5,
    );
  });

  test('E2: fakta semantik membawa tag & importance kandidat tertinggi',
      () async {
    final memory = memoryWithOldEpisodes(5, importance: 0.7);
    final llm = _ScriptedLlm('- fakta penting\n');
    final c = IdleMemoryConsolidator(
      memory: memory,
      llm: llm,
      config: cfg,
    );
    await c.maybeConsolidate(now: now);
    final semantic = memory.all
        .where((e) => e.layer == MemoryLayerType.semantic)
        .toList();
    expect(semantic, hasLength(1));
    expect(semantic.first.importance, 0.7);
    expect(semantic.first.tags, contains('konsolidasi-idle'));
  });
}

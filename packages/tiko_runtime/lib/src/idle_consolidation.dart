library;

import 'package:agent_core/agent_core.dart';
import 'package:agent_memory/agent_memory.dart';

/// E2 — konsolidasi memori berbasis LLM saat "idle" (opt-in).
///
/// Ide (dari wishlist Qwen, versi jujur): entri episodik yang retensinya
/// sudah rendah (hampir terlupakan) dikonsolidasi menjadi beberapa fakta
/// semantik padat via LLM auxiliar, sehingga pengetahuan yang layak bertahan
/// tanpa menumpuk detail mentah. Entri asli TIDAK dihapus — hanya ditandai
/// `consolidated` dan dibiarkan dilupakan oleh mekanisme decay/floor yang
/// sudah ada (B-series).
///
/// Batasan jujur:
/// - "Idle" di sini = jeda antar giliran chat yang cukup panjang (diukur
///   dari hitung giliran sejak konsolidasi terakhir), BUKAN timer latar
///   belakang atau isolate terpisah.
/// - Opt-in (default false) karena membakar token LLM.
/// - Cap harian ketat: maksimal N panggilan LLM per UTC day.
/// - Parsing output LLM fail-closed: baris tidak valid dibuang; tanpa fakta
///   valid, TIDAK ada perubahan memori.
class IdleConsolidationConfig {
  const IdleConsolidationConfig({
    this.enabled = false,
    this.idleTurns = 25,
    this.minCandidates = 5,
    this.maxEntriesPerBatch = 20,
    this.maxSummariesPerDay = 6,
    this.maxRetention = 0.5,
    this.maxOutputFacts = 8,
  });

  final bool enabled;

  /// Jumlah giliran sejak konsolidasi terakhir sebelum pass dijalankan.
  final int idleTurns;

  /// Kandidat minimum; di bawah ini pass dibatalkan tanpa panggilan LLM.
  final int minCandidates;

  /// Batas entri episodik per batch (ukuran prompt terkendali).
  final int maxEntriesPerBatch;

  /// Cap panggilan LLM konsolidasi per UTC day.
  final int maxSummariesPerDay;

  /// Hanya entri episodik dengan retensi <= nilai ini yang jadi kandidat
  /// (fokus: yang hampir terlupakan).
  final double maxRetention;

  /// Batas fakta semantik yang diterima dari satu jawaban LLM.
  final int maxOutputFacts;
}

/// Hasil satu pass konsolidasi idle.
class IdleConsolidationReport {
  const IdleConsolidationReport({
    required this.candidates,
    required this.factsAdded,
  });

  /// Jumlah entri episodik yang dikonsolidasi.
  final int candidates;

  /// Jumlah fakta semantik baru yang ditambahkan.
  final int factsAdded;

  Map<String, dynamic> toJson() => {
        'candidates': candidates,
        'facts_added': factsAdded,
      };
}

/// Pengecualian konsolidasi idle (LLM gagal / jawaban tidak valid).
class IdleConsolidationException implements Exception {
  const IdleConsolidationException(this.message);
  final String message;

  @override
  String toString() => 'IdleConsolidationException: $message';
}

class IdleMemoryConsolidator {
  IdleMemoryConsolidator({
    required LayeredMemory memory,
    required LlmProvider llm,
    this.config = const IdleConsolidationConfig(),
    void Function(String type, Map<String, dynamic> data)? onEvent,
  })  : _memory = memory,
        _llm = llm,
        _onEvent = onEvent;

  final LayeredMemory _memory;
  final LlmProvider _llm;
  final IdleConsolidationConfig config;
  final void Function(String type, Map<String, dynamic> data)? _onEvent;

  int _turnsSinceRun = 0;
  final Map<String, int> _runsByDay = {};

  /// Dipanggil host setiap giliran chat; memicu pass saat ambang idle
  /// tercapai. Best-effort: error ditelan (dilaporkan via event `error`
  /// saja) dan tidak pernah menggagalkan giliran.
  Future<IdleConsolidationReport?> noteTurn({DateTime? now}) async {
    _turnsSinceRun++;
    if (_turnsSinceRun < config.idleTurns) return null;
    _turnsSinceRun = 0;
    return maybeConsolidate(now: now);
  }

  /// Jalankan satu pass konsolidasi (dipanggil [noteTurn] atau langsung).
  ///
  /// Return null bila pass dibatalkan (belum ada kandidat cukup, cap
  /// harian habis, atau LLM tidak menghasilkan fakta valid).
  Future<IdleConsolidationReport?> maybeConsolidate({DateTime? now}) async {
    final at = (now ?? DateTime.now()).toUtc();
    final day = at.toIso8601String().substring(0, 10);

    // Cap harian: setiap panggilan LLM dihitung, sukses atau tidak.
    if ((_runsByDay[day] ?? 0) >= config.maxSummariesPerDay) return null;

    final candidates = _collectCandidates(at);
    if (candidates.length < config.minCandidates) return null;

    _runsByDay[day] = (_runsByDay[day] ?? 0) + 1;

    final List<String> facts;
    try {
      facts = await _summarize(candidates);
    } catch (e) {
      _onEvent?.call('memory.idle_consolidation_error', {
        'error': e.toString(),
        'day': day,
      });
      return null;
    }
    if (facts.isEmpty) return null;

    final maxImportance =
        candidates.map((c) => c.importance).reduce((a, b) => a > b ? a : b);
    for (final fact in facts) {
      _memory.add(
        MemoryLayerType.semantic,
        fact,
        importance: maxImportance,
        tags: const ['konsolidasi-idle'],
        sourceSession: candidates.first.sourceSession,
        now: at,
      );
    }
    for (final c in candidates) {
      c.consolidated = true;
    }
    final report = IdleConsolidationReport(
      candidates: candidates.length,
      factsAdded: facts.length,
    );
    _onEvent?.call('memory.idle_consolidated', {
      ...report.toJson(),
      'day': day,
    });
    return report;
  }

  /// Kandidat: episodik, belum terkonsolidasi, retensi rendah; terlama
  /// dulu (deterministik), dibatasi
  /// [IdleConsolidationConfig.maxEntriesPerBatch].
  List<MemoryEntry> _collectCandidates(DateTime at) {
    final scored = <MemoryEntry>[];
    for (final entry in _memory.all) {
      if (entry.layer != MemoryLayerType.episodic) continue;
      if (entry.consolidated) continue;
      final retention =
          entry.retention(at, halfLifeDays: _memory.halfLifeDays);
      if (retention > config.maxRetention) continue;
      scored.add(entry);
    }
    scored.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return scored.take(config.maxEntriesPerBatch).toList();
  }

  /// Panggil LLM auxiliar dengan prompt ketat; parsing fail-closed.
  Future<List<String>> _summarize(List<MemoryEntry> candidates) async {
    final buf = StringBuffer();
    for (final c in candidates) {
      final text =
          c.text.length > 300 ? '${c.text.substring(0, 300)}…' : c.text;
      buf.writeln('- $text');
    }
    final request = ChatRequest(
      messages: [
        const ChatMessage(
          role: 'system',
          content: '''
You are a strict memory-consolidation assistant for an agent runtime.

Rules:
1. Input is a list of episodic memory entries (raw event notes).
2. Reply with 1 to MAX facts, one per line, each starting with "- ".
3. Each fact must be a compact, generalizable statement (max 200 chars)
   that stays true to the input. No IDs, no timestamps, no filler.
4. Never invent facts that are not supported by the input.
5. If nothing is worth keeping, reply with exactly: NONE
''',
        ),
        ChatMessage(
          role: 'user',
          content: 'Maksimal ${config.maxOutputFacts} fakta.\n\n'
              'Entri episodik:\n$buf',
        ),
      ],
      stream: false,
      temperature: 0.0,
      maxTokens: 1024,
    );
    final response = await _llm.chat(request).first;
    if (response is! LlmTextDelta) {
      throw const IdleConsolidationException(
          'LLM konsolidasi tidak menghasilkan teks');
    }
    return _parseFacts(response.delta);
  }

  /// Parsing fail-closed: hanya baris "- " yang divalidasi (tidak kosong,
  /// tidak oversize, dibatasi [IdleConsolidationConfig.maxOutputFacts]).
  List<String> _parseFacts(String raw) {
    if (raw.trim().toUpperCase() == 'NONE') return const [];
    final facts = <String>[];
    for (final line in raw.split('\n')) {
      final trimmed = line.trim();
      if (!trimmed.startsWith('- ')) continue;
      final fact = trimmed.substring(2).trim();
      if (fact.isEmpty) continue;
      if (fact.length > 300) continue;
      facts.add(fact);
      if (facts.length >= config.maxOutputFacts) break;
    }
    return facts;
  }
}

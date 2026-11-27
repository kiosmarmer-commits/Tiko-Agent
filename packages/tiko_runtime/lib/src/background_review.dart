part of 'tiko_runtime.dart';

/// Hermes background review (`agent/background_review.py`): setelah turn
/// kasar (gagal atau boros tool-call), jalankan satu panggilan LLM aux atas
/// snapshot transcript untuk memutuskan "apakah ada skill/memory yang perlu
/// disimpan atau diperbarui?". Deviasi sadar dari Hermes:
/// - Hermes mem-fork agent lengkap dengan toolset memory/skill; Tiko memakai
///   satu panggilan LLM non-tool dengan output JSON terbatas — penulisan
///   skill/memory tetap lewat jalur validasi runtime yang ada (tidak
///   menduplikasi [SelfEvolutionEngine] maupun self-learning).
/// - Hermes memakai daemon thread; Tiko memakai [Timer] idle + unawaited
///   future (single-isolate), dengan cooldown per sesi dan batas transcript.
/// - Never-raises: kegagalan provider/parse hanya event `review.failed`.
class ReviewTurnSignals {
  const ReviewTurnSignals({
    required this.success,
    required this.toolCalls,
  });

  final bool success;
  final int toolCalls;
}

/// Hasil satu review latar; tersimpan bounded per sesi untuk observasi.
class ReviewOutcome {
  const ReviewOutcome({
    required this.sessionId,
    required this.nothingToSave,
    required this.memoryOps,
    required this.skillOps,
    required this.at,
  });

  final String sessionId;
  final bool nothingToSave;
  final List<Map<String, dynamic>> memoryOps;
  final List<Map<String, dynamic>> skillOps;
  final DateTime at;

  Map<String, dynamic> toJson() => {
        'session': sessionId,
        'nothing_to_save': nothingToSave,
        'memory_ops': memoryOps,
        'skill_ops': skillOps,
        'at': at.toIso8601String(),
      };
}

class BackgroundReviewEngine {
  BackgroundReviewEngine({
    required this.config,
    required this.events,
    required this.auxiliaryLlm,
    required this.transcriptOf,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final ReviewConfig config;
  final EventBus events;
  final LlmProvider? Function() auxiliaryLlm;
  final Future<List<ChatMessage>> Function(String sessionId) transcriptOf;
  final DateTime Function() _clock;

  final Map<String, DateTime> _lastReviewAt = {};
  final Map<String, Timer> _pending = {};
  final Map<String, ReviewOutcome> _lastOutcomes = {};
  bool _closed = false;

  /// Hermes: review kasar dipicu turn gagal atau boros iterasi tool-call.
  static const roughToolCallThreshold = 8;

  /// Batas FIFO state per-sesi (konvensi runtime: 500 entri).
  static const maxTrackedSessions = 500;

  /// Batas ops per review (fail-open, jangan biarkan model menggenjot).
  static const maxMemoryOps = 5;
  static const maxSkillOps = 3;
  static const maxOpChars = 2000;

  /// Dipanggil runtime di akhir tiap turn; jadwalkan review bila kasar.
  void noteTurnEnd(
    String sessionId, {
    required bool success,
    required int toolCalls,
  }) {
    if (!config.enabled || _closed) return;
    if (success && toolCalls < roughToolCallThreshold) return;
    final now = _clock();
    final last = _lastReviewAt[sessionId];
    if (last != null &&
        now.difference(last) < Duration(seconds: config.cooldownSec)) {
      return;
    }
    _pending[sessionId]?.cancel();
    _pending[sessionId] = Timer(
      Duration(seconds: config.idleDelaySec),
      () {
        _pending.remove(sessionId);
        unawaited(_safeReview(sessionId));
      },
    );
  }

  /// Jalankan review sekarang (dipakai scheduler idle dan pengujian).
  /// Return null bila tak layak / gagal (event `review.failed`).
  Future<ReviewOutcome?> reviewNow(String sessionId) => _safeReview(sessionId);

  Map<String, dynamic>? lastOutcome(String sessionId) =>
      _lastOutcomes[sessionId]?.toJson();

  Future<ReviewOutcome?> _safeReview(String sessionId) async {
    if (!config.enabled || _closed) return null;
    final now = _clock();
    final last = _lastReviewAt[sessionId];
    if (last != null &&
        now.difference(last) < Duration(seconds: config.cooldownSec)) {
      return null;
    }
    _evict(_lastReviewAt);
    _lastReviewAt[sessionId] = now;
    try {
      final aux = auxiliaryLlm();
      if (aux == null) return null;
      final history = await transcriptOf(sessionId);
      if (history.length < config.minMessages) return null;
      final prompt = buildBackgroundReviewPrompt(
        history,
        maxTranscriptChars: config.maxTranscriptChars,
      );
      final buf = StringBuffer();
      await for (final e in aux.chat(
        ChatRequest(
          messages: [ChatMessage(role: 'user', content: prompt)],
          stream: false,
        ),
      )) {
        if (e is LlmTextDelta) buf.write(e.delta);
        if (e is LlmError) return _fail(sessionId, 'provider error');
      }
      // Jawaban tanpa JSON valid = model gagal mengikuti format — jujur
      // dilaporkan `review.failed` (bukan diam-diam dianggap nothing).
      final outcome = parseReviewVerdict(sessionId, buf.toString(), now);
      if (outcome == null) {
        return _fail(sessionId, 'verdict bukan JSON yang valid');
      }
      _evict(_lastOutcomes);
      _lastOutcomes[sessionId] = outcome;
      events.emit('review.completed', outcome.toJson());
      return outcome;
    } catch (e) {
      return _fail(sessionId, '$e');
    }
  }

  ReviewOutcome? _fail(String sessionId, String error) {
    events.emit('review.failed', {'session': sessionId, 'error': error});
    return null;
  }

  void _evict<V>(Map<String, V> map) {
    while (map.length >= maxTrackedSessions) {
      map.remove(map.keys.first);
    }
  }

  Future<void> close() async {
    _closed = true;
    for (final t in _pending.values) {
      t.cancel();
    }
    _pending.clear();
  }
}

/// Hermes `_COMBINED_REVIEW_PROMPT` (diringkas, bahasa runtime): review
/// transcript, putuskan update memory/skill, bias AKTIF — sesi tanpa catatan
/// adalah peluang belajar yang terlewat, bukan hasil netral.
String buildBackgroundReviewPrompt(
  List<ChatMessage> history, {
  int maxTranscriptChars = 12000,
}) {
  final lines = <String>[];
  var used = 0;
  for (final m in history.reversed) {
    final content = m.content.trim();
    if (content.isEmpty) continue;
    final line = '${m.role}: $content';
    if (used + line.length > maxTranscriptChars) break;
    used += line.length;
    lines.add(line);
  }
  final transcript = lines.reversed.join('\n\n');
  return 'Tinjau percakapan berikut (snapshot, baca-saja).\n\n$transcript\n\n'
      'Tugas: putuskan apakah ada yang perlu disimpan atau diperbarui.\n\n'
      '**Memory**: fakta identitas, preferensi, atau situasi user yang layak '
      'persisten. Memory berisi "siapa user dan kondisi operasi saat ini".\n\n'
      '**Skill**: cara mengerjakan kelas tugas ini. Koreksi user (gaya, '
      'format, verbosity, pendekatan) adalah sinyal first-class. Teknik, '
      'fix, workaround, atau jalur debugging non-trivial layak dicatat. '
      'Bias AKTIF: sesi tanpa catatan adalah peluang belajar yang terlewat, '
      'bukan hasil netral — tapi jangan mengarang bila memang tidak ada.\n\n'
      'Balas HANYA JSON tanpa penjelasan, bentuk persis:\n'
      '{"nothing_to_save": false, "memory": [{"action": "add", "content": '
      '"..."}], "skills": [{"action": "add", "name": "slug-kebab", '
      '"content": "..."}]}\n\n'
      'Aturan: action memory = add|replace|remove; action skill = add|patch; '
      'maksimal 5 memory dan 3 skill; konten tiap op maksimal 2000 karakter; '
      'jika benar-benar tidak ada sinyal, gunakan {"nothing_to_save": true, '
      '"memory": [], "skills": []}.';
}

/// Parser verdict JSON dari jawaban LLM: ambil blok `{...}` pertama, terima
/// hanya bentuk yang dikenal, batasi jumlah dan panjang ops (fail-open:
/// jawaban tak valid => null, pemanggil memperlakukan sebagai nothing).
ReviewOutcome? parseReviewVerdict(
  String sessionId,
  String answer,
  DateTime at,
) {
  final text = answer.trim();
  final start = text.indexOf('{');
  final end = text.lastIndexOf('}');
  if (start < 0 || end <= start) return null;
  final Map<String, dynamic> json;
  try {
    final decoded = jsonDecode(text.substring(start, end + 1));
    if (decoded is! Map<String, dynamic>) return null;
    json = decoded;
  } catch (_) {
    return null;
  }
  List<Map<String, dynamic>> parseOps(
    Object? raw,
    int cap,
    Set<String> allowedActions,
  ) {
    if (raw is! List) return const [];
    final out = <Map<String, dynamic>>[];
    for (final e in raw) {
      if (e is! Map<String, dynamic>) continue;
      final action = e['action'];
      if (action is! String || action.trim().isEmpty) continue;
      final normalized = action.trim().toLowerCase();
      if (!allowedActions.contains(normalized)) continue;
      final op = <String, dynamic>{
        'action': normalized,
        for (final k in const ['name', 'content', 'old_text'])
          if (e[k] is String &&
              (e[k] as String).trim().isNotEmpty)
            k: (e[k] as String).trim().substring(
                  0,
                  (e[k] as String).trim().length > BackgroundReviewEngine.maxOpChars
                      ? BackgroundReviewEngine.maxOpChars
                      : (e[k] as String).trim().length,
                ),
      };
      out.add(op);
      if (out.length >= cap) break;
    }
    return List.unmodifiable(out);
  }

  return ReviewOutcome(
    sessionId: sessionId,
    nothingToSave: json['nothing_to_save'] == true,
    memoryOps: parseOps(
      json['memory'],
      BackgroundReviewEngine.maxMemoryOps,
      const {'add', 'replace', 'remove'},
    ),
    skillOps: parseOps(
      json['skills'],
      BackgroundReviewEngine.maxSkillOps,
      const {'add', 'patch'},
    ),
    at: at,
  );
}

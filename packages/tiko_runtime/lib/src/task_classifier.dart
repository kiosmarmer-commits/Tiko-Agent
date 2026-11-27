/// Fase 31 — Task classifier + algorithm router (audit 2026-11-28 §7.2,
/// "TaskMode internal, bukan 20 agent baru"): classifier heuristik
/// deterministik yang audit-able — TANPA panggilan LLM, TANPA hak mengubah
/// security/permission. Output mode hanya *advisory telemetry*: host/GUI
/// memakainya untuk observability; jalur eksekusi (AgentLoop ReAct) tetap
/// sama seperti sebelumnya, jadi kontrak chat tidak berubah.
///
/// Mode mengikuti tabel §7.2 laporan:
/// - fast          : pertanyaan pendek/fakta umum, tanpa sinyal tools.
/// - tool          : ada tindakan (buat/kirim/jadwalkan/jalankan/ubah).
/// - plan          : banyak langkah/dependensi (rencana, step-by-step).
/// - deepReasoning : keputusan penting/ketidakpastian tinggi (arsitektur,
///                   trade-off, strategi, analisis mendalam).
/// - research      : butuh sumber eksternal + laporan.
/// - coding        : perubahan repo/kode (fence, ekstensi file, error build).
/// - knowledge     : query dokumen internal (vault/catatan/dokumen).
///
/// Prioritas deterministik: coding > research > knowledge > plan >
/// deepReasoning > tool > fast. Keyword ekstra bisa ditambah via config
/// `task_classifier:` tanpa mengubah kode.
library;

import 'tiko_config.dart';

/// Mode tugas hasil klasifikasi heuristik (§7.2).
enum TaskMode { fast, tool, plan, deepReasoning, research, coding, knowledge }

/// Hasil klasifikasi: mode + sinyal yang match (bebas konten — hanya nama
/// sinyal, tidak pernah menyimpan isi pesan pengguna) + alasan singkat.
class TaskModeAssessment {
  const TaskModeAssessment({
    required this.mode,
    this.signals = const [],
    this.matchedKeywords = const [],
    this.inputChars = 0,
  });

  final TaskMode mode;

  /// Nama sinyal yang aktif (mis. `code_fence`, `research_keyword`).
  final List<String> signals;

  /// Keyword yang match (huruf kecil, maks 8) — bebas konten.
  final List<String> matchedKeywords;
  final int inputChars;

  Map<String, dynamic> toJson() => {
        'mode': mode.name,
        'signals': signals,
        'matched_keywords': matchedKeywords,
        'input_chars': inputChars,
      };
}

/// Classifier heuristik — stateless, thread-safe, deterministik (input sama
/// → mode sama). Never-raises: input apa pun menghasilkan assessment.
class TaskClassifier {
  const TaskClassifier({this.config = const TaskClassifierCfg()});

  final TaskClassifierCfg config;

  static const _codingKeywords = [
    'refactor', 'refaktor', 'stack trace', 'compile', 'kompilasi',
    'build error', 'build gagal', 'unit test', 'debugging', 'debug kode',
    'perbaiki kode', 'implementasikan fungsi', 'implementasi fungsi',
    'git commit', 'merge conflict', 'pull request', 'lint error',
  ];
  static const _codingExtensions = [
    r'\.dart\b', r'\.py\b', r'\.ts\b', r'\.js\b', r'\.java\b', r'\.go\b',
    r'\.rs\b', r'\.cpp\b', r'\.c\b', r'\.kt\b', r'\.swift\b', r'\.sh\b',
  ];
  static const _researchKeywords = [
    'riset', 'research', 'teliti mendalam', 'kaji bandingkan',
    'bandingkan sumber', 'laporan mendalam', 'literature', 'survei pasar',
    'sumber terpercaya', 'state of the art', 'trend analis',
  ];
  static const _knowledgeKeywords = [
    'dari catatan', 'di catatan', 'di vault', 'dokumen internal',
    'di dokumen saya', 'sesuai catatan', 'indeks pengetahuan',
  ];
  static const _planKeywords = [
    'langkah demi langkah', 'step by step', 'step-by-step', 'buat rencana',
    'rencanakan', 'roadmap', 'dekomposisi', 'pecah jadi langkah',
    'jadwal implementasi',
  ];
  static const _deepKeywords = [
    'trade-off', 'tradeoff', 'arsitektur', 'desain sistem', 'strategi',
    'analisis mendalam', 'pilih pendekatan', 'evaluasi risiko',
    'risiko migrasi', 'keputusan penting',
  ];
  static const _toolKeywords = [
    'buatkan', 'buat file', 'tulis file', 'simpan ke', 'kirim pesan',
    'kirim email', 'jadwalkan', 'ingatkan', 'jalankan perintah',
    'unduh', 'hapus file', 'ubah file', 'salin file', 'cron', 'telegram',
    'discord', 'slack', 'whatsapp',
  ];

  /// Klasifikasi satu pesan. `[internalCommand]` dipisahkan host — perintah
  /// `/…` tidak perlu diklasifikasi.
  TaskModeAssessment classify(String input, {bool internalCommand = false}) {
    if (!config.enabled || internalCommand) {
      return TaskModeAssessment(mode: TaskMode.fast, inputChars: input.length);
    }
    final chars = input.length;
    final signals = <String>[];
    final matched = <String>{};
    final lower = input.toLowerCase();

    void scan(String signal, List<String> builtin, String cfgKey) {
      for (final kw in builtin) {
        if (lower.contains(kw)) {
          signals.add(signal);
          matched.add(kw);
        }
      }
      for (final kw in config.keywordsFor(cfgKey)) {
        final k = kw.toLowerCase().trim();
        if (k.isNotEmpty && lower.contains(k)) {
          signals.add('${signal}_custom');
          matched.add(k);
        }
      }
      for (final ext in _codingExtensions) {
        if (RegExp(ext).hasMatch(lower)) {
          signals.add('file_extension');
          break;
        }
      }
    }

    if (input.contains('```')) {
      signals.add('code_fence');
    }
    scan('coding_keyword', _codingKeywords, 'coding');
    scan('research_keyword', _researchKeywords, 'research');
    scan('knowledge_keyword', _knowledgeKeywords, 'knowledge');
    scan('plan_keyword', _planKeywords, 'plan');
    scan('deep_keyword', _deepKeywords, 'deep');
    scan('tool_keyword', _toolKeywords, 'tool');
    if (input.contains('@file:') || input.contains('@folder:')) {
      signals.add('context_ref');
    }

    TaskMode mode;
    if (signals.any((s) => s.startsWith('coding') || s == 'code_fence')) {
      mode = TaskMode.coding;
    } else if (signals.any((s) => s.startsWith('research'))) {
      mode = TaskMode.research;
    } else if (signals.any((s) => s.startsWith('knowledge'))) {
      mode = TaskMode.knowledge;
    } else if (signals.any((s) => s.startsWith('plan'))) {
      mode = TaskMode.plan;
    } else if (signals.any((s) => s.startsWith('deep'))) {
      mode = TaskMode.deepReasoning;
    } else if (signals.any((s) => s.startsWith('tool') || s == 'context_ref')) {
      mode = TaskMode.tool;
    } else {
      mode = TaskMode.fast;
    }

    // Fast hanya untuk input pendek; input panjang tanpa sinyal dianggap
    // pertanyaan butuh konteks (tetap jalur ReAct biasa — advisory saja).
    if (mode == TaskMode.fast && chars > config.fastMaxChars) {
      signals.add('long_input');
      mode = TaskMode.tool;
    }

    return TaskModeAssessment(
      mode: mode,
      signals: List.unmodifiable(signals),
      matchedKeywords:
          List.unmodifiable(matched.take(8)),
      inputChars: chars,
    );
  }
}

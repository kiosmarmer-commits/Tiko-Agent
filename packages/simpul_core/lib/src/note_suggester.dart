import 'ollama_chat.dart';

/// Note improvement operations (AI-24). Results are always SUGGESTIONS —
/// applying them is a human decision (AI-41 human-in-the-loop); nothing is
/// ever written back automatically.
enum SuggestOp {
  ringkasan,
  tulisUlang,
  terjemahan,
  ekstraksiTugas;

  static SuggestOp parse(String value) {
    final key = value.trim().toLowerCase();
    return switch (key) {
      'ringkasan' || 'summary' => SuggestOp.ringkasan,
      'tulis-ulang' || 'tulis_ulang' || 'rewrite' => SuggestOp.tulisUlang,
      'terjemahan' || 'translate' => SuggestOp.terjemahan,
      'tugas' || 'ekstraksi-tugas' || 'tasks' => SuggestOp.ekstraksiTugas,
      _ => throw ArgumentError(
          'operasi tidak dikenal: $value (pilihan: ringkasan, tulis-ulang, '
          'terjemahan, tugas)',
        ),
    };
  }

  String get label => switch (this) {
        SuggestOp.ringkasan => 'ringkasan',
        SuggestOp.tulisUlang => 'tulis-ulang',
        SuggestOp.terjemahan => 'terjemahan',
        SuggestOp.ekstraksiTugas => 'ekstraksi-tugas',
      };
}

/// Local-LLM note suggestions (AI-24): summary, rewrite, translation, and
/// task extraction on a selected note. The result is a proposed text the
/// caller shows as a suggestion (diff-style), never an overwrite.
class NoteSuggester {
  NoteSuggester({required this.chat});

  final OllamaChat chat;

  static const _systemPrompt =
      'Anda asisten penulisan vault lokal. Keluaran Anda adalah SARAN — '
      'pengguna yang memutuskan menerapkannya (human-in-the-loop, AI-41). '
      'Keluarkan hanya hasilnya tanpa pembuka atau penutup.';

  Future<String> suggest(
    SuggestOp op,
    String noteText, {
    String? targetLang,
  }) {
    final instruction = switch (op) {
      SuggestOp.ringkasan =>
        'Ringkas catatan berikut menjadi 3-6 poin utama. Pertahankan istilah '
            'penting dan nama tautan.',
      SuggestOp.tulisUlang =>
        'Tulis ulang catatan berikut dengan bahasa yang lebih jelas dan '
            'terstruktur tanpa mengubah makna.',
      SuggestOp.terjemahan =>
        'Terjemahkan catatan berikut ke bahasa ${targetLang ?? 'Inggris'}. '
            'Pertahankan format Markdown, tautan [[wiki]], tag #, dan prop.',
      SuggestOp.ekstraksiTugas =>
        'Ekstrak semua tugas/action items dari catatan berikut sebagai daftar '
            'checkbox Markdown ("- [ ] "). Jika tidak ada tugas, tulis '
            '"Tidak ada tugas".',
    };
    return chat.complete(
      '$instruction\n\n---\n$noteText\n---',
      system: _systemPrompt,
    );
  }
}

/// Title generator (Hermes parity: `agent/title_generator.py`): judul sesi
/// otomatis dari pesan pembuka user, dua tahap keduanya di luar jalur kritis
/// jawaban — (1) **instant** judul deterministik (tidak bisa gagal), lalu
/// (2) **upgrade** satu panggilan model kecil (JSON-constrained) dengan guard
/// answer-shaped agar jawaban model tak pernah menjadi judul sesi.
/// Provenance `derived < llm < user`: tahap 2 hanya mengganti tahap 1 dan
/// tidak pernah mengganti nama yang diketik user.
library;

import 'dart:async';
import 'dart:convert';

import 'interfaces.dart';
import 'models.dart';

/// Provenance rank — sumber lebih tinggi tidak pernah ditimpa sumber lebih
/// rendah (`derived` 0 < `llm` 1 < `user` 2).
int titleRank(String source) => switch (source) {
      'derived' => 0,
      'llm' => 1,
      'user' => 2,
      _ => 0,
    };

/// Batas karakter input yang diberikan ke model (konvergensi Claude Code /
/// OpenClaw pada 1000).
const int maxTitleInputChars = 1000;

/// Cap judul instant; fragmen mentah makin panjang makin buruk dibaca.
const int maxDerivedTitleChars = 48;

/// Guard answer-shaped: judul tugas 3–7 kata; model kecil kadang menjawab
/// pesan user sebagai ganti men-judul-nya — jawaban itu tidak boleh menjadi
/// judul sesi. 12 kata menyisakan ruang judul sah yang agak panjang.
const int _maxTitleWords = 12;

/// Guard answer-shaped CJK: Han/kana/Hangul tak ber-spasi sehingga hitungan
/// kata buta; balasan adalah kalimat — >20 char (dengan tanda baca kalimat)
/// atau >40 char (tanpa) ditolak.
const int _maxTitleCjkChars = 20;
const int _maxUnpunctuatedTitleCjkChars = 40;

final RegExp _cjkRe = RegExp(
  r'[\u3000-\u303f\u3040-\u30ff\u3400-\u4dbf\u4e00-\u9fff\uac00-\ud7af'
  r'\uff01-\uff9f]',
);

int _cjkCharCount(String s) => _cjkRe.allMatches(s).length;

bool _hasSentencePunctuation(String s) =>
    RegExp(r'[.!?。！？…．]', unicode: true).hasMatch(s);

/// Pesan layak di-judulkan: non-empty, bukan perintah slash/internal, cukup
/// panjang untuk bermakna.
bool isTitleableUserMessage(String text) {
  final t = text.trim();
  if (t.length < 4) return false;
  if (t.startsWith('/')) return false;
  return true;
}

String _firstLine(String text) {
  for (final raw in text.split('\n')) {
    final l = raw.trim();
    if (l.isNotEmpty) return l;
  }
  return '';
}

/// Judul instant deterministik dari pesan pembuka user; null bila tidak ada
/// fragmen yang layak. Tidak pernah gagal dan tidak pernah memanggil LLM.
String? deriveTitle(String userMessage) {
  var line = _firstLine(userMessage.trim());
  if (line.isEmpty) return null;
  // Strip wrapper ringan: heading markdown dan prefix perintah percakapan.
  line = line.replaceFirst(RegExp(r'^#{1,6}\s*'), '');
  line = line.replaceAll(RegExp(r'\s+'), ' ').trim();
  final refRe = RegExp(r'@(?:file|folder):\S+');
  line = line.replaceAll(refRe, ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
  if (line.isEmpty) return null;
  if (line.length <= maxDerivedTitleChars) {
    return _tidy(line);
  }
  // Potong di batas kata agar fragmen tidak terpotong di tengah kata.
  var cut = line.substring(0, maxDerivedTitleChars);
  final lastSpace = cut.lastIndexOf(' ');
  if (lastSpace > maxDerivedTitleChars ~/ 2) {
    cut = cut.substring(0, lastSpace);
  }
  return _tidy(cut);
}

String _tidy(String s) {
  var t = s.trim();
  while (t.isNotEmpty && const ['.', ',', ';', ':', '-', '—'].contains(t[t.length - 1])) {
    t = t.substring(0, t.length - 1).trim();
  }
  return t;
}

/// Ekstrak teks judul dari output model: coba JSON `{"title": ...}` dulu,
/// lalu fallback teks polos bersih dari wrapper. Null bila tak ada.
String? _extractTitleText(String raw) {
  var text = raw.trim();
  if (text.isEmpty) return null;
  final start = text.indexOf('{');
  final end = text.lastIndexOf('}');
  if (start >= 0 && end > start) {
    try {
      final json = jsonDecode(text.substring(start, end + 1));
      if (json is Map) {
        final t = json['title'];
        if (t is String && t.trim().isNotEmpty) text = t.trim();
      }
    } catch (_) {
      // JSON korup → lanjut ke ekstraksi teks polos.
    }
  }
  text = text.trim();
  // Buang wrapper fence/prefix percakapan ringan.
  text = text.replaceFirst(RegExp(r'^```(?:json)?\s*'), '');
  text = text.replaceFirst(RegExp(r'```\s*$'), '');
  text = text.replaceFirst(
      RegExp(r'^(?:judul|title)\s*[:：]\s*', caseSensitive: false), '');
  text = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  // Hapus kutip pembungkus.
  if (text.length >= 2 &&
      ((text.startsWith('"') && text.endsWith('"')) ||
          (text.startsWith("'") && text.endsWith("'")))) {
    text = text.substring(1, text.length - 1).trim();
  }
  if (text.isEmpty) return null;
  return text;
}

/// Guard answer-shaped atas kandidat judul; true = layak dipakai.
bool isAcceptableTitle(String title) {
  final t = title.trim();
  if (t.isEmpty || t.contains('\n')) return false;
  if (t.length > maxTitleInputChars ~/ 2) return false;
  final cjk = _cjkCharCount(t);
  if (cjk > 0) {
    if (_hasSentencePunctuation(t) && cjk > _maxTitleCjkChars) return false;
    if (!_hasSentencePunctuation(t) && cjk > _maxUnpunctuatedTitleCjkChars) {
      return false;
    }
  }
  final words = t
      .split(RegExp(r'\s+'))
      .where((w) => !_cjkRe.hasMatch(w))
      .length;
  if (words > _maxTitleWords) return false;
  return true;
}

/// Tahap 2 — upgrade judul dengan satu panggilan model kecil (thinking off,
/// JSON-constrained). Null bila gagal/tak layak; never-raises, timeout 15s
/// agar judul tak pernah memperlambat turn tanpa batas.
Future<String?> upgradeTitleWithLlm(
  LlmProvider aux,
  String userMessage,
) async {
  try {
    final input = userMessage.trim();
    final clipped = input.length > maxTitleInputChars
        ? input.substring(0, maxTitleInputChars)
        : input;
    final req = ChatRequest(
      messages: [
        const ChatMessage(
          role: 'system',
          content: 'Anda pembuat judul sesi obrolan. Balas HANYA JSON '
              '{"title": "..."} tanpa penjelasan.',
        ),
        ChatMessage(
          role: 'user',
          content: 'Beri judul pendek (maks 8 kata, bahasa pesan) untuk sesi '
              'yang dibuka pesan ini:\n\n$clipped',
        ),
      ],
      stream: false,
      temperature: 0.2,
      maxTokens: 64,
    );
    final buf = StringBuffer();
    await for (final e in aux.chat(req).timeout(const Duration(seconds: 15))) {
      switch (e) {
        case LlmTextDelta(:final delta):
          buf.write(delta);
        case LlmError():
          return null;
        default:
          break;
      }
    }
    final title = _extractTitleText(buf.toString());
    if (title == null) return null;
    if (!isAcceptableTitle(title)) return null;
    return title;
  } catch (_) {
    return null;
  }
}

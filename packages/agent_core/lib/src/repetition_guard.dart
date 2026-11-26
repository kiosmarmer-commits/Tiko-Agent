/// Repetition guard (Hermes `agent/repetition_guard.py`): cek kewarasan
/// konten murah untuk output model — final maupun masih streaming.
///
/// Model dalam loop repetisi degenerate bisa menghabiskan SELURUH budget
/// output mengulang satu fragmen. Ini mendeteksi fragmen yang didominasi
/// repetisi SEBELUM dikirim sehingga turn dibatalkan dengan error jelas.
/// Sengaja konservatif: hanya repeat verbatim PANJANG (60+ char) yang
/// mayoritas cakupannya yang dipicu. Fail-open untuk input pendek.
library;

import 'dart:math' as math;

/// Di bawah panjang ini cek tidak berjalan: truncation pendek memang
/// mengandung token berulang dan sah untuk dilanjutkan.
const int minFragmentLength = 400;

/// Jendela repeat eksak; jauh melampaui pemakaian frasa wajar.
const int _repeatWindow = 60;

/// Jendela yang mengulang sekurang-kurangnya sering ini adalah sinyal.
const int _minRepeatCount = 5;

/// "Dominasi repetisi" = jendela berulang mencakup ≥ fraksi ini.
const double _dominanceRatio = 0.5;

const int _maxAnchorSamples = 32;
const int _maxAnchorMatches = 8;

/// Path stop membuang jawaban LENGKAP, jadi hanya abort pada skala runaway.
const int stopPathMinChars = 16000;

const int _streamTailChars = 4 * stopPathMinChars;

const double _runawayDistinctLineRatio = 0.5;

/// Pesan pengganti saat jawaban degenerate — jangan replay byte loop.
const String repetitionLoopInterrupted =
    '[jawaban degenerate menjadi loop repetisi dan dipotong]';

/// True bila run kontigu ≥ 5 repeat eksak mencakup ≥ separuh teks —
/// signature loop repetisi model. Cakupan diukur dengan periode sejati,
/// jadi unit loop multi-baris panjang terhitung penuh. Fail-open pendek.
bool isRepetitionDominated(String text) {
  final n = text.length;
  if (n < minFragmentLength) return false;

  if (_lineRepetitionDominated(text, n)) return true;
  return _windowCountDominated(text, n) || _periodicRunDominated(text, n);
}

/// Lebih ketat: dominasi repetisi + bentuk runaway (baris duplikat, bukan
/// baris batch yang mirip tapi berbeda).
bool isRunawayRepetition(String text) {
  if (!isRepetitionDominated(text)) return false;
  final lines = text
      .split('\n')
      .map((l) => l.trim())
      .where((l) => l.isNotEmpty)
      .toList();
  if (lines.length < _minRepeatCount) {
    return true; // tak ada struktur baris untuk dinilai: loop satu baris
  }
  return lines.toSet().length <= lines.length * _runawayDistinctLineRatio;
}

bool _lineRepetitionDominated(String text, int n) {
  final counts = <String, int>{};
  for (final raw in text.split('\n')) {
    final norm = raw.trim();
    if (norm.isEmpty) continue;
    counts[norm] = (counts[norm] ?? 0) + 1;
  }
  for (final e in counts.entries) {
    if (e.value >= _minRepeatCount &&
        e.value * e.key.length >= n * _dominanceRatio) {
      return true;
    }
  }
  return false;
}

bool _windowCountDominated(String text, int n) {
  final needed = math.max(
    _minRepeatCount,
    (n * _dominanceRatio / _repeatWindow).ceil(),
  );
  final counts = <String, int>{};
  for (var i = 0; i <= n - _repeatWindow; i++) {
    final key = text.substring(i, i + _repeatWindow);
    final c = (counts[key] ?? 0) + 1;
    if (c >= needed) return true;
    counts[key] = c;
  }
  return false;
}

/// Deteksi run periodik eksak dominan dari anchor berjarak merata.
/// Anchor 60-char yang cocok di posisi lain memberi kandidat periode;
/// ekspansi dua arah memulihkan run penuh, sehingga cakupan diukur dengan
/// unit pengulangan sejati, bukan hanya 60 char per kemunculan.
bool _periodicRunDominated(String text, int n) {
  final maxStart = n - _repeatWindow;
  if (maxStart < 1) return false;

  final sampleStep = math.max(
    1,
    (maxStart + _maxAnchorSamples - 2) ~/ (_maxAnchorSamples - 1),
  );
  final sampleStarts = <int>[
    for (var s = 0; s <= maxStart; s += sampleStep) s,
  ];
  if (sampleStarts.last != maxStart) sampleStarts.add(maxStart);

  final rejected = <(int, int, int)>[];
  for (final start in sampleStarts) {
    final anchor = text.substring(start, start + _repeatWindow);
    var searchFrom = start + 1;
    for (var m = 0; m < _maxAnchorMatches; m++) {
      final match = text.indexOf(anchor, searchFrom);
      if (match < 0) break;
      final period = match - start;
      searchFrom = match + 1;
      final alreadyRejected = rejected.any(
        (r) => r.$1 <= start && start < r.$2 && period % r.$3 == 0,
      );
      if (alreadyRejected) continue;
      final run = _expandRun(text, n, start, period, _repeatWindow);
      final len = run.$2 - run.$1;
      if (len >= _minRepeatCount * period &&
          len >= n * _dominanceRatio) {
        return true;
      }
      rejected.add((run.$1, run.$2, period));
    }
  }
  return false;
}

(int, int) _expandRun(String text, int n, int start, int period, int matched) {
  var left = start;
  while (left > 0 && text[left - 1] == text[left - 1 + period]) {
    left--;
  }
  var right = start + matched;
  while (right + period < n && text[right] == text[right + period]) {
    right++;
  }
  return (left, right + period);
}

/// Kriteria stop-path diterapkan SELAMA satu channel (teks visible atau
/// reasoning) mengalir. Check pertama pada [stopPathMinChars]; gap berlipat
/// dua sampai satu tail window lalu konstan. Tiap check hanya membaca tail,
/// jadi total kerja linear terhadap ukuran output.
class RunawayStreamWatch {
  final List<String> _parts = [];
  int _chars = 0;
  int _nextCheck = stopPathMinChars;

  int get charsSeen => _chars;

  /// Tambahkan satu delta; true begitu channel menjadi runaway loop.
  bool feed(String text) {
    if (text.isEmpty) return false;
    _parts.add(text);
    _chars += text.length;
    if (_chars < _nextCheck) return false;
    _nextCheck = _chars + math.min(_chars, _streamTailChars);
    final joined = _parts.join();
    final tail = joined.length > _streamTailChars
        ? joined.substring(joined.length - _streamTailChars)
        : joined;
    _parts
      ..clear()
      ..add(tail);
    return isRunawayRepetition(tail);
  }
}

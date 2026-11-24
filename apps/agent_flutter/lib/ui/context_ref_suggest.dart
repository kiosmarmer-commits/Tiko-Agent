/// Context reference composer helpers (FR-03 paritas): parsing chip
/// `@file:`, `@dir:`, `@url:`, `@git:` dan saran autocomplete saat caret
/// berada di dalam token. Pure-Dart agar mudah diuji tanpa widget.
library;

/// Kinds yang didukung runtime (paritas ContextExpander FR-03).
const List<String> kContextRefKinds = ['file', 'dir', 'url', 'git'];

/// Mode git yang valid untuk `@git:` (paritas `@git:diff|log|status`).
const List<String> kGitModes = ['diff', 'log', 'status'];

/// Saran token builtin yang tinggal dipilih (tanpa data remote).
const List<String> kBuiltinSuggestions = [
  '@file:',
  '@dir:',
  '@url:',
  '@git:diff',
  '@git:log',
  '@git:status',
];

/// Satu token context reference di dalam teks composer.
class ContextRefToken {
  const ContextRefToken({
    required this.kind,
    required this.target,
    required this.start,
    required this.end,
  });

  /// `file` | `dir` | `url` | `git`.
  final String kind;

  /// Target setelah `:` (path relatif, URL, atau mode git).
  final String target;

  /// Offset awal token (posisi `@`).
  final int start;

  /// Offset akhir token (eksklusif).
  final int end;

  String get fullLabel =>
      '@$kind${target.isEmpty ? ':' : ':$target'}';
}

/// State saran aktif di posisi caret.
class ContextRefSuggestion {
  const ContextRefSuggestion({
    this.builtins = const [],
    this.activeKind,
    this.targetPrefix = '',
    this.entries = const [],
  });

  /// Saran builtin (semua atau terfilter prefix).
  final List<String> builtins;

  /// `file`/`dir` bila caret menembak target path (perlu daftar workspace),
  /// `git` untuk saran mode, `url` saat mengetik URL manual, null bila bukan
  /// token aktif.
  final String? activeKind;

  /// Prefix target yang sedang diketik (mis. `src/li`).
  final String targetPrefix;

  /// Entri workspace (path) yang cocok — diisi pemanggil via repo.
  final List<String> entries;

  bool get isEmpty =>
      builtins.isEmpty &&
      entries.isEmpty &&
      activeKind == null;
}

final RegExp _refRe = RegExp(
  r'@(file|dir|url|git):([^\s]*)',
  caseSensitive: false,
);

/// Parsing semua token context reference di [text].
///
/// Sintaks runtime (ContextExpander): `@file:<path>`, `@dir:<path>`,
/// `@url:<url>`, `@git:(diff|log|status)`. Target tidak boleh mengandung
/// spasi (paritas regex runtime `@...:([^\s]+)`).
List<ContextRefToken> parseContextRefs(String text) {
  return [
    for (final match in _refRe.allMatches(text))
      ContextRefToken(
        kind: match.group(1)!.toLowerCase(),
        target: match.group(2) ?? '',
        start: match.start,
        end: match.end,
      ),
  ];
}

/// Hapus rentang [start]..[end] dari [text] (tombol delete chip).
String removeRange(String text, int start, int end) {
  if (start < 0 || end > text.length || start >= end) return text;
  return text.replaceRange(start, end, '');
}

/// Token aktif di [caret] (caret berada di dalam rentang token), atau null.
ContextRefToken? activeTokenAt(String text, int caret) {
  for (final m in _refRe.allMatches(text)) {
    if (caret > m.start && caret <= m.end) {
      return ContextRefToken(
        kind: m.group(1)!.toLowerCase(),
        target: m.group(2) ?? '',
        start: m.start,
        end: m.end,
      );
    }
  }
  return null;
}

/// Saran saat pengguna mengetik partial builtin (mis. `@fi`) sebelum kolon:
/// mengembalikan builtin yang cocok, atau daftar kosong bila bukan.
List<String> builtinPartials(String text, int caret) {
  final from = caret - 1;
  if (from < 0 || from >= text.length) return const [];
  final at = text.lastIndexOf('@', from);
  if (at < 0) return const [];
  final page = text.substring(at, caret);
  if (page.isEmpty || page.contains(' ')) return const [];
  final partial = page.substring(1).toLowerCase();
  if (partial.contains(':')) return const [];
  return [
    for (final s in kBuiltinSuggestions)
      if (s.substring(1).toLowerCase().startsWith(partial)) s,
  ];
}

/// Susun saran di [caret]. [entries] adalah path file workspace dari
/// `/v1/artifacts` (pemanggil yang melakukan fetch + debounce).
ContextRefSuggestion suggestAt(
  String text,
  int caret, {
  List<String> entries = const [],
}) {
  final active = activeTokenAt(text, caret);
  if (active == null) {
    return ContextRefSuggestion(builtins: builtinPartials(text, caret));
  }
  final kind = active.kind;
  if (kind == 'file' || kind == 'dir') {
    final prefix = active.target;
    final matches = [
      for (final e in entries)
        if (e.toLowerCase().startsWith(prefix.toLowerCase())) e,
    ];
    return ContextRefSuggestion(
      activeKind: kind,
      targetPrefix: active.target,
      entries: matches,
    );
  }
  if (kind == 'git') {
    final prefix = '@git:${active.target}';
    return ContextRefSuggestion(
      activeKind: 'git',
      targetPrefix: active.target,
      builtins: [
        for (final mode in kGitModes)
          // `@git:<prefix>` adalah prefix dari `@git:<mode>` — sehingga
          // ketik `d` menyarankan diff, ketik kosong menyarankan ketiganya.
          if ('@git:$mode'.toLowerCase().startsWith(prefix.toLowerCase()))
            '@git:$mode',
      ],
    );
  }
  return ContextRefSuggestion(
    activeKind: 'url',
    targetPrefix: active.target,
  );
}

/// Direktori parent unik dari daftar path file — dipakai untuk chip `@dir:`
/// dari listing `/v1/artifacts` (endpoint hanya mengembalikan file).
List<String> parentDirsOf(List<String> filePaths) => {
      for (final path in filePaths)
        if (path.contains('/')) path.substring(0, path.lastIndexOf('/')),
    }.toList()..sort();

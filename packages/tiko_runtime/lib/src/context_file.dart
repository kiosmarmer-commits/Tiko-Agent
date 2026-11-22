import 'dart:io';

import 'package:path/path.dart' as p;

/// A.1 — Project context file (TIKO.md / AGENTS.md / CLAUDE.md / GEMINI.md),
/// setara `CLAUDE.md`-nya Claude Code dan `GEMINI.md`-nya Gemini CLI:
/// file panduan di root workspace yang disuntikkan ke system prompt setiap
/// turn tanpa perlu user mereferensikannya secara eksplisit.
///
/// Prinsip fail-closed + jujur:
/// - Hanya dibaca dari root workspace (bukan rekursif) untuk menghindari
///   kejutan dari file di subfolder.
/// - Prioritas satu file saja (bukan gabungan): TIKO.md > AGENTS.md >
///   CLAUDE.md > GEMINI.md — satu sumber kebenaran, tanpa drift antar file.
/// - Batas 12.000 karakter (sejalan AGENTS.md): sisanya dipotong dengan
///   penanda jujur, bukan diam-diam dipenuhi ke konteks.
/// - Tidak pernah throw: kegagalan baca menjadi null (tanpa blok).
class ProjectContextFile {
  const ProjectContextFile({
    required this.fileName,
    required this.filePath,
    required this.content,
    this.truncated = false,
  });

  final String fileName;
  final String filePath;
  final String content;
  final bool truncated;
}

/// Kandidat standar (urutan prioritas). `TIKO.md` di depan agar proyek Tiko
/// bisa punya instruksi khusus; tiga lainnya hanya fallback
/// interoperabilitas dengan agent lain.
const kProjectContextCandidates = [
  'TIKO.md',
  'AGENTS.md',
  'CLAUDE.md',
  'GEMINI.md',
];

const kProjectContextMaxChars = 12000;

/// Mencari dan membaca project context file dari [workspaceRoot].
/// Mengembalikan null bila tidak ada kandidat atau gagal dibaca.
ProjectContextFile? resolveProjectContextFile({
  required String workspaceRoot,
  List<String> candidates = kProjectContextCandidates,
  int maxChars = kProjectContextMaxChars,
}) {
  for (final name in candidates) {
    final probe = File(_join(workspaceRoot, name));
    if (!probe.existsSync()) continue;
    try {
      final raw = probe.readAsStringSync();
      final content = raw.trim();
      if (content.isEmpty) continue;
      final truncated = content.length > maxChars;
      return ProjectContextFile(
        fileName: name,
        filePath: probe.path,
        content: truncated ? content.substring(0, maxChars) : content,
        truncated: truncated,
      );
    } catch (_) {
      // File tidak terbaca (izin dsb.) — lanjut ke kandidat berikutnya.
      continue;
    }
  }
  return null;
}

String _join(String root, String name) => p.join(root, name);

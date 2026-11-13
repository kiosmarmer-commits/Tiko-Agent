/// Simpul Core — fondasi indeks vault Markdown lokal-first yang kompatibel
/// dengan Obsidian (wikilink, embed, frontmatter, tag, block id).
///
/// Paket ini tidak memiliki dependensi pada agent_core/agent_memory; ia
/// memakai ulang pola yang sama (fail-closed, tulis atomik tmp+rename,
/// clock/injectable) agar mudah diaudit bersama Tiko.
library;

export 'src/benchmark.dart';
export 'src/graph_csr.dart';
export 'src/note_parser.dart';
export 'src/vault_generator.dart';
export 'src/vault_index.dart';
export 'src/vault_scanner.dart';

/// Simpul Core — fondasi indeks vault Markdown lokal-first yang kompatibel
/// dengan Obsidian (wikilink, embed, frontmatter, tag, block id).
///
/// Paket ini tidak memiliki dependensi pada agent_core/agent_memory; ia
/// memakai ulang pola yang sama (fail-closed, tulis atomik tmp+rename,
/// clock/injectable) agar mudah diaudit bersama Tiko.
library;

export 'src/ai_permissions.dart';
export 'src/benchmark.dart';
export 'src/community.dart';
export 'src/embedding.dart';
export 'src/eval_corpus.dart';
export 'src/graph_cache.dart';
export 'src/graph_csr.dart';
export 'src/hybrid_search.dart';
export 'src/isolate_layout.dart';
export 'src/ivf_index.dart';
export 'src/layout_cache.dart';
export 'src/link_suggester.dart';
export 'src/multi_level_layout.dart';
export 'src/quadtree.dart';
export 'src/rag.dart';
export 'src/note_parser.dart';
export 'src/note_suggester.dart';
export 'src/ollama_chat.dart';
export 'src/ollama_embedder.dart';
export 'src/semantic_index.dart';
export 'src/tag_suggester.dart';
export 'src/vault_crypto.dart';
export 'src/vault_generator.dart';
export 'src/vault_index.dart';
export 'src/vault_index_sqlite_stub.dart'
    if (dart.library.ffi) 'src/vault_index_sqlite.dart';
export 'src/vault_modes.dart';
export 'src/vault_scanner.dart';
export 'src/vault_sync.dart';
export 'src/vault_watcher.dart';
export 'src/force_layout.dart';

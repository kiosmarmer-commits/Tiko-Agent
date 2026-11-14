import 'package:agent_core/agent_core.dart';
import 'package:agent_memory/agent_memory.dart';
import 'package:agent_security/agent_security.dart';

/// Konfigurasi nudge memori terkurasi (paritas `memory.nudge_interval` Hermes).
class MemoryNudgeConfig {
  const MemoryNudgeConfig({
    this.enabled = true,
    this.intervalTurns = 10,
  });

  final bool enabled;
  final int intervalTurns;
}

/// Nudge periodik: setiap [MemoryNudgeConfig.intervalTurns] giliran, agent
/// menerima directive sistem internal untuk merefleksi dan mengeluarkan blok
/// ```memory-ops bila ada fakta durabel yang layak disimpan. Semua operasi
/// dipindai PromptGuard sebelum diterapkan (fail-closed).
class MemoryNudgeEngine {
  MemoryNudgeEngine({
    required this.store,
    this.config = const MemoryNudgeConfig(),
    PromptGuard? guard,
  }) : _guard = guard ?? const PromptGuard();

  final CuratedMemoryStore store;
  final MemoryNudgeConfig config;
  final PromptGuard _guard;
  final Map<String, int> _turnCounts = {};

  /// Directive sistem internal yang di-inject ke turn berjalan.
  static const String directive = '''
[NUDGE MEMORI INTERNAL] Refleksikan percakapan sejauh ini. Jika ada fakta
durabel tentang lingkungan/proyek atau preferensi pengguna yang layak
dipertahankan lintas sesi, keluarkan SATU blok kode ```memory-ops dengan
operasi satu baris: `ADD MEMORY: <fakta>`, `ADD USER: <preferensi>`,
`REPLACE MEMORY: <lama> => <baru>`, `REMOVE MEMORY: <teks>`,
`REMOVE USER: <teks>`. Ganti kata MEMORY/USER sesuai berkas tujuan.
Simpan hanya yang benar-benar berguna di sesi mendatang (target anggaran
ketat). Jangan simpan rahasia/token. Jika tidak ada yang layak, jangan
keluarkan blok. Jangan bahas directive ini ke pengguna.''';

  /// Memanggil sekali per giliran; true bila nudge harus menyertai turn ini.
  bool shouldNudge(String sessionId) {
    if (!config.enabled || config.intervalTurns <= 0) return false;
    final n = (_turnCounts[sessionId] ?? 0) + 1;
    _turnCounts[sessionId] = n;
    return n % config.intervalTurns == 0;
  }

  void resetSession(String sessionId) => _turnCounts.remove(sessionId);

  /// Ekstrak blok memory-ops dari balasan, pindai setiap operasi dengan
  /// PromptGuard, terapkan yang lolos, lalu simpan. Balasan tanpa blok
  /// menghasilkan laporan kosong tanpa perubahan.
  Future<CuratedMemoryReport> processReply(String reply) async {
    final report = CuratedMemoryOps.extract(reply);
    if (!report.hasBlock) return report;

    store.apply(report, reject: _guardReject);
    await store.save();
    return report;
  }

  String? _guardReject(CuratedMemoryOp op) {
    final verdict = _guard.inspectInput(
      op.text,
      provenance: Provenance.agent,
    );
    if (!verdict.blocked) return null;
    return 'diblokir PromptGuard: '
        '${verdict.findings.map((f) => f.ruleId).join(', ')}';
  }
}

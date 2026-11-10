# Perbaikan: Metrik Skill Durabel (uses/successes)

- Tanggal: 2026-11-09
- Repo: `kiosmarmer-commits/Tiko-Agent` (branch `main`)
- Bloker: "skill metrics (uses/successes) hanya in-memory" dari `TIKO-REPAIR-STATUS-2026-11-07.md`
- Jejak audit: feat `a9b94e8` ("feat(skills): metrik uses/successes durabel via SkillMetricsLedger + sink registry")

## Masalah

`Skill.uses`/`Skill.successes` hanya hidup di memori `SkillRegistry`. Setiap restart `loadFromDirectory` memuat ulang skill dari `SKILL.md` (yang memang tidak menyimpan metrik — dan tidak boleh, karena frontmatter bisa diedit user), sehingga semua riwayat pemakaian hilang. Heuristik auto-retire (`approved` dengan `uses >= 5` dan `successRate < 0.6`) juga selalu mulai dari nol dan tidak pernah punya data cukup untuk bekerja.

## Desain

1. **`SkillMetricsLedger`** (`packages/agent_core/lib/src/skill_metrics.dart`) — ledger JSON di `<dataDir>/skill_metrics.json` dengan `SkillUsageMetrics {uses, successes, positive, negative, lastUsedAt}`. Tulis atomik (tmp + rename), fail-closed saat korup (ledger kosong — kehilangan telemetri lebih baik daripada angka palsu), pruning entri terlama di atas `maxSkills` (default 2000) tanpa pernah membuang entri yang baru dicatat.
2. **Sink registry** — `SkillRegistry` mendapat dua callback opsional `onUseRecorded`/`onFeedbackRecorded` yang dipanggil fire-and-forget (`unawaited` + `catchError`) di akhir `recordUse`/`applyFeedback`. Kegagalan menulis ledger tidak pernah menggagalkan giliran agent.
3. **Pemisahan sumber kebenaran** — `applyTo(SkillRegistry)` hanya memulihkan angka `uses`/`successes`; status skill tetap milik `SkillApprovalLedger`. Telemetri tidak pernah mempromosikan/menurunkan status skill — hanya heuristik retire dalam memori yang membacanya.
4. **Wiring runtime** — `TikoRuntime.create` membuat ledger di `skill_metrics.json`, memuat + menerapkannya ke registry, dan memasang sink; `rt.skillMetrics` diekspos untuk admin/API.

## Matriks test

| Test | Yang diverifikasi |
| --- | --- |
| `packages/agent_core/test/skill_metrics_test.dart` (6 test) | persist & reload `recordUse`; `recordFeedback` terpisah dari uses; file korup → ledger kosong; `applyTo` hanya angka; pruning; sink registry dipanggil (polling, tanpa delay tetap) |
| `packages/tiko_runtime/test/skill_metrics_durability_test.dart` | end-to-end: approve skill → chat memicu trigger → sink menulis file (polling maks 1 detik) → restart memulihkan `uses` di registry dan ledger |

`AgentLoop` tetap satu-satunya pencatat pemakaian: `recordUse` hanya dipanggil untuk skill yang match trigger dengan status bukan draft/retired, dengan `success` = keberhasilan giliran.

## Keterbatasan

- Sink fire-and-forget: crash tepat setelah giliran agent bisa kehilangan satu event terakhir (diterima — telemetri, bukan transaksi).
- Feedback 👍/👎 (`applyFeedback`) belum dipanggil dari loop chat; sink sudah siap untuk channel feedback (Flutter/REST) berikutnya.
- Tidak ada agregat historis per-hari; hanya counter kumulatif + `lastUsedAt`.

## Status

Selesai; menunggu konfirmasi CI hijau di HEAD setelah commit docs ini.

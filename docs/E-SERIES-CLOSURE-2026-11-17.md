# Laporan Penutupan E-Series — Wishlist Qwen v2 → Implementasi Jujur

**Tanggal:** 2026-11-17
**Status:** E-series selesai. Semua item feasible terimplementasi & merged;
sisa item dilaporkan blocked dengan alasan eksplisit.

## Latar

Analisis laporan strategis Qwen v2 (setelah D-series) menghasilkan rencana
E-series: item yang **belum** tercakup D-series dan feasible di pure Dart.
Prinsip tetap sama: **framing jujur** — detektor statistik bukan "agen imun
otonom", hitung giliran bukan "timer idle latar belakang", checksum bukan
tanda tangan kriptografis.

## Rekap E1–E4

| Item | PR | Yang diimplementasikan | Test baru | Status |
|---|---|---|---|---|
| **E1 — Deteksi anomali token per skill** ("immune-lite") | #79 | `TokenAnomalyDetector` (agent_security): baseline rolling per skill (FIFO 50, mean+stddev), dua lantai z-score 3.0 + rasio 3.0x (anti false-positive baseline datar), cooldown 60 menit, fail-closed minSamples 5; wiring opt-in `security.token_anomaly` (default false): event `security.token_anomaly` + AuditLog + karantina skill ke draft (cap harian 3, pola B4); bug nyata ditemukan test: `_stddev` mengembalikan varians (lupa sqrt) — diperbaiki | 14 | ✅ Merged |
| **E2 — Konsolidasi memori idle via LLM** | #80 | `IdleMemoryConsolidator` (tiko_runtime): entri episodik retensi rendah (≤0.5) diringkas jadi fakta semantik via LLM auxiliar; pemicu idle = hitung giliran ≥25 (bukan timer); gerbang kandidat minimum; parsing fail-closed (NONE/baris tak valid dibuang); cap harian 6 panggilan LLM; entri asli tidak dihapus (decay/floor Ebbinghaus yang melupakan); opt-in `memory.idle_consolidation` | 13 | ✅ Merged |
| **E3 — Install skill lokal + SHA-256** | #81 | `tiko skills install <path> [--sha256 <hex>]` — `SkillLocalInstaller` (agent_tools): paket JSON D5 / SKILL.md / direktori; verifikasi SHA-256 konstanta-waktu fail-closed (mismatch → tanpa file tertulis), SkillValidator + rescan rahasia, status dipaksa draft di file juga, collision ditolak keras, path safety; bug nyata: hint slug dari nama file `SKILL.md` → slug `skill` — diperbaiki | 9 | ✅ Merged |
| **E4 — Pustaka widget Flutter reusable** | #81 | Paket `apps/tiko_widgets` (di luar workspace Dart, sengaja): `GenUiMessageView`/`GenUiView` (D1) + `RoutingSummary` diekstrak dari agent_flutter + `TikoChatInterface` BARU (bubble + input + GenUI, tanpa dependensi API client); agent_flutter memakai shim re-export (78 test tetap hijau); job CI baru `tiko-widgets` | 5 | ✅ Merged |

**Total: 41 test baru**, plus 2 bug nyata ditemukan & diperbaiki selama
pengembangan (E1 sqrt, E3 slug hint) dan 1 keputusan arsitektur terdokumentasi
(paket Flutter di luar workspace Dart + job CI khusus).

## Pemetaan wishlist Qwen v2 → kenyataan (jujur)

| Wishlist Qwen v2 | Verdict awal | Hasil akhir |
|---|---|---|
| 🛡️ "Immune System Agent" — anomali token per skill | Gap nyata | E1: detektor ambang statistik yang MELAPORKAN + karantina via mekanisme approval yang ada; klaim "agen keamanan otonom" tidak dibuat |
| 🛡️ "Immune System" — self-healing tools otomatis | Tidak feasible aman | **Tidak diimplementasi** — perbaikan skill tetap jalur manusia/evolution; dilaporkan eksplisit |
| 🔄 Ebbinghaus compaction proaktif (LLM summarization) | Feasible dengan batasan | E2: ringkasan LLM saat idle (hitung giliran, bukan timer); klaim "background isolate / database kecil selamanya" tidak dibuat |
| 🧩 Skill Marketplace + `tiko skill install` | CLI feasible; registry blocked | E3: install lokal + SHA-256 + draft; registry server publik = BLOCKED (butuh infrastruktur) |
| 📱 DX Flutter: widget siap pakai (`tiko_flutter`) | Feasible, gap nyata | E4: paket `tiko_widgets` (GenUI renderer + status + chat interface); pub.dev belum dipublikasikan — jujur |

## Sisa item blocked (butuh sumber daya eksternal)

| Item | Penghalang | Buka lagi bila |
|---|---|---|
| Registry server skill publik | Butuh server + keputusan produk + trust model | Ada infrastruktur hosting & kebijakan publikasi |
| Tanda tangan kriptografis paket skill | Butuh key management + keputusan trust | Ada skema signing yang disepakati |
| FFI HNSW (LanceDB/usearch) | Merusak pure-Dart/web story; butuh binaries per platform | Ada keputusan produk untuk binary deps |
| whisper.cpp / llama.cpp FFI | Butuh binaries + QA perangkat | Ada device QA + izin distribusi binary |
| CRDT real-time sync antar perangkat | Butuh transport sync (server/relay) | Ada infrastruktur transport |
| Wasm runtime untuk agent_core | `dart:io` di agent_core; dart2wasm eksperimental | Refactor besar + toolchain matang |
| SLAM/AR, SMTP live relay, gateway real-world, device QA | Butuh perangkat/kredensial nyata | Ada akses device/kredensial |

## Dokumen rujukan per item

- E1: `TOKEN-ANOMALY-E1-2026-11-17.md` (indeks 50)
- E2: `IDLE-CONSOLIDATION-E2-2026-11-17.md` (indeks 51)
- E3: `SKILL-INSTALL-CLI-E3-2026-11-17.md` (indeks 52)
- E4: `WIDGET-LIBRARY-E4-2026-11-17.md` (indeks 53)
- Seri sebelumnya: `D-SERIES-CLOSURE-2026-11-17.md` (indeks 49)

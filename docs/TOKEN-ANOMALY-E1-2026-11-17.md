# E1: Deteksi Anomali Token per Skill ("immune-lite") — 2026-11-17

## Ringkasan

E1 menutup gap nyata dari laporan strategis Qwen ("Immune System Agent"): belum ada
deteksi lonjakan pemakaian token **per skill**. `AnomalyDetector` yang sudah ada
(`prompt_guard.dart`) hanya mendeteksi laju event per key (rate-based), bukan
pemakaian token.

Yang dibangun adalah versi **jujur**: detektor ambang statistik sederhana yang
MELAPORKAN anomali dan menyerahkan penindakan ke mekanisme yang sudah ada
(audit log, event bus, karantina skill). **Bukan** "agen keamanan otonom" — tidak
ada agen latar belakang, tidak ada keputusan otonom di luar cap, tidak ada klaim
pembelajaran.

## Komponen

### 1. `TokenAnomalyDetector` (`packages/agent_security/lib/src/token_anomaly.dart`)

- Baseline rolling per skill: jendela FIFO (default 50 sampel), mean + simpangan
  baku populasi.
- Aturan lonjakan: `tokens > max(mean + z*stddev, mean * minSpikeRatio)`.
  Dua lantai sekaligus: z-score (default 3.0) **dan** lantai rasio (default 3.0x)
  — lantai rasio mencegah false positive saat baseline datar (stddev ≈ 0).
- Fail-closed: minimal `minSamples` (default 5) sebelum alarm mungkin; sebelum itu
  baseline belum bermakna.
- Cooldown per skill (default 60 menit) — anti-spam alarm.
- Sampel pemicu tetap dicatat (baseline ikut bergerak), tapi tidak masuk baseline
  nilai yang sedang dinilai.
- `statsFor(slug)` untuk introspeksi; `reset([slug])`.

### 2. Wiring `tiko_runtime`

- Config opt-in `security.token_anomaly` (default **false**): bentuk ringkas
  `true` atau mapping penuh (`enabled`, `min_samples`, `window_size`,
  `z_multiplier`, `min_spike_ratio`, `cooldown_minutes`,
  `max_quarantines_per_day`). Nilai tidak valid → `ConfigIssue` + fallback
  default (fail-closed).
- Setelah tiap giliran chat (`chatWithStatus`), total token giliran diobservasi
  untuk **setiap skill yang dipakai giliran itu**.
- Saat anomali terdeteksi:
  1. Event `security.token_anomaly` (slug, tokens, baseline_mean, threshold,
     samples, session, quarantined).
  2. Entri `AuditLog` (tool `token_anomaly`, risk medium, verdict
     `anomali`/`anomali-karantina`).
  3. Karantina konservatif: skill status → draft + `approvedBy` null, dengan
     **cap harian** (default 3/UTC day) dan skill draft/retired dilewati —
     pola sama dengan karantina reward-collapse di Self-Evolution Engine (B4).
  4. Pelajaran korektif ke reflection engine (best-effort).
- Best-effort total: kegagalan deteksi/audit tidak pernah menggagalkan giliran.

## Atribusi token (jujur)

Token giliran diatribusikan **utuh ke setiap skill yang dipakai giliran itu**.
Jika satu giliran memakai 3 skill, ketiganya tercatat total yang sama — bisa
dobel hitung antar skill. Ini pendekatan konservatif (lebih sensitif, tidak
pernah melewatkan lonjakan), dan atribusi per-token-call presisi membutuhkan
instrumentasi provider per tool call yang tidak ada saat ini.

## Batasan (dilaporkan jujur)

- Detektor ambang statistik, **bukan** model pembelajaran atau "agen imun".
- Tidak ada "self-healing tools otomatis" (usulan Qwen lainnya) — E1 hanya
  mendeteksi dan mengkarantina; perbaikan skill tetap jalur manusia/evolution.
- Karantina in-memory (sama dengan B4); status frontmatter SKILL.md tidak
  ditulis ulang.
- Tidak menghitung token per tool call individual; unit observasi = giliran.

## Pengujian

- `packages/agent_security/test/token_anomaly_test.dart` — 10 test: baseline
  minimum, lonjakan terdeteksi, variasi normal tidak alarm, baseline datar
  (lantai rasio), cooldown, baseline per-skill terpisah, FIFO window, reset,
  input tidak valid, statsFor.
- `packages/tiko_runtime/test/token_anomaly_wiring_test.dart` — 3 test:
  nonaktif default (detektor null), lonjakan → karantina + event, cap harian +
  skill draft dilewati.
- `packages/tiko_runtime/test/tiko_config_test.dart` — +1 test parsing config.

Total: **14 test baru**. `dart analyze --fatal-warnings` bersih di
agent_security, tiko_runtime, agent_core, agent_tools, agentd; `dart test`
hijau (tiko_runtime 241, agent_security 97, agentd 7).

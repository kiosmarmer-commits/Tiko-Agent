# D5 — Federated-Lite: Skill Export/Import + Merge Metrik LWW

**Tanggal:** 2026-11-17
**Status:** Implementasi selesai, ter-wire di runtime, diuji.

## Ringkasan

D5 mengimplementasikan versi **jujur dan realistis** dari wishlist Qwen
"Federated Swarm Learning": berbagi skill antar instance Tiko secara manual
via paket JSON tervalidasi, plus merge metrik agregat dengan CRDT
**LWW-Register** agar pengalaman (counter uses/successes) dua instance bisa
bergabung tanpa konflik.

## Posisi yang jujur (vs wishlist "Federated Swarm Learning")

- **BUKAN federated learning sungguhan** — tidak ada gradient update, tidak
  ada jaringan swarm otomatis, tidak ada server agregasi.
- Yang ada: **ekspor/impor manual** (tool `skill_share`) + **merge metrik
  LWW** — cukup untuk berbagi pengalaman antar instance milik satu orang
  atau tim kecil, tanpa infrastruktur.
- **Privasi by design**: paket hanya berisi konten skill + counter agregat
  (uses/successes/golden). Tidak ada transkrip, data user, path mesin,
  atau approval record.

## Desain teknis

### Paket (`SkillPackage`, agent_core)

- Format `tiko-skill-package` v1: `exported_at`, `instance_id` opsional,
  `skill{slug,name,description,body,triggers,tools,version,metrics}`.
- **Ekspor fail-closed**: skill yang gagal `SkillValidator.validate`
  (rahasia terdeteksi: API key, password, private key, `curl | sh`; atau
  oversize) **ditolak untuk diekspor**.
- **Impor fail-closed dua arah**: parse ketat (format/version/field/tipe),
  konten impor discan ulang dengan pola rahasia yang sama.
- **Trust tidak ikut berpindah**: skill impor SELALU `draft`,
  `approvedBy` null — aktivasi tetap lewat SkillPromotionGate + approval
  eksplisit (konsisten dengan kebijakan PRD §9.5).

### Merge metrik (`SkillMetricsMerger`)

- **LWW-Register**: snapshot dengan `updated_at` terbaru menang; seri →
  local menang (deterministik); local null → remote menang.
- Trade-off didokumentasikan: bukan PN-Counter — kenaikan counter di kedua
  sisi sejak snapshot terakhir bisa hilang bila satu sisi jauh lebih baru.
  Dipilih karena sederhana, konvergen, dan cukup untuk berbagi manual.
- Validasi metrik: `successes <= uses`, semua non-negatif, timestamp ISO.

### Tool `skill_share` (risk medium)

- `export` (slug) → paket JSON pretty (redaksi fail-closed).
- `import` (package, `as_slug` opsional):
  - slug bentrok dengan isi berbeda → **ditolak** (sarankan `as_slug`).
  - slug bentrok isi identik → skill lokal dipertahankan, **hanya metrik
    di-merge LWW** (bug "register menimpa lokal" ditemukan & diperbaiki
    saat pengujian).
  - skill baru → didaftarkan sebagai draft + dipersist ke
    `skills/<slug>/SKILL.md` **hanya bila direktori belum ada** (tidak
    pernah menimpa skill lokal di disk).
- Tanpa koneksi jaringan apa pun — berbagi dilakukan manusia (copy-paste
  paket JSON antar perangkat).

## Wiring

- `packages/agent_core/lib/src/skill_share.dart` — modul inti.
- `packages/tiko_runtime/lib/src/tiko_runtime.dart` —
  `..register(SkillShareTool(registry: skillRegistry, skillsRoot: abs('skills')))`.

## Pengujian

`packages/agent_core/test/skill_share_test.dart` — **22 test**:

- Redaksi ekspor fail-closed (API key) & impor dua arah (private key).
- Trust & data mesin tidak ikut (status/approved_by/path/sha256 absent).
- Round-trip export→parse→toSkill (draft, metrik utuh, reload disk OK).
- Parse ketat: format/version salah, field wajib hilang, slug invalid,
  version 0, JSON rusak, `successes > uses`.
- LWW: remote lebih baru / local lebih baru / seri → local / local null.
- Tool: export valid & slug tidak ada; import baru + persist; bentrok
  isi beda → tolak tanpa timpa; bentrok isi sama → merge LWW (dua arah);
  as_slug; paket rusak; package kosong; aksi tidak dikenal.

Hasil lokal: `dart analyze --fatal-warnings` bersih; `dart test`:
agent_core **247 passing**, tiko_runtime **237 passing**, agentd
**7 passing**.

## Batasan (by design, terdokumentasi)

- Berbagi manual — tidak ada sinkronisasi otomatis antar instance.
- LWW pada counter agregat, bukan PN-Counter (lihat trade-off di atas).
- Metrik lokal tidak menyimpan `updated_at` per skill — saat merge dengan
  skill lokal yang ada, waktu lokal dipakai "sekarang" (lokal selalu
  dianggap lebih segar daripada paket ekspor lama).

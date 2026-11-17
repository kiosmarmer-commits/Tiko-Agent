# E3: CLI Install Skill Lokal + Verifikasi SHA-256 — 2026-11-17

## Ringkasan

E3 menutup gap dari laporan Qwen ("Tiko Skill Marketplace"): perintah
`tiko skills install <path>` untuk memasang skill dari **sumber lokal** —
tanpa registry server (bagian marketplace/registry pusat tetap BLOCKED,
dilaporkan jujur). Yang sudah ada sebelumnya: `skills hub install <id>`
(butuh `TIKO_SKILLS_HUB_URL`) dan `skills import <dir>` (agentskills.io,
langsung register in-memory tanpa verifikasi integritas).

## Komponen

### 1. `SkillLocalInstaller` (`packages/agent_tools/lib/src/skill_local_install.dart`)

Sumber yang diterima:
1. Berkas `.json` berisi paket `tiko-skill-package` (hasil export D5).
2. Direktori berisi `SKILL.md` (slug dari nama direktori).
3. Berkas markdown SKILL.md tunggal (slug dari frontmatter `name`).

Keamanan (fail-closed):
- **Verifikasi SHA-256 opsional**: `--sha256 <hex>` → byte sumber harus cocok
  persis (perbandingan konstanta-waktu) sebelum apa pun diproses; mismatch →
  exception, tidak ada file yang ditulis.
- `SkillPackage.parse` ketat + rescan rahasia; `SkillValidator.validate`
  dipanggil lagi setelah parse.
- Status **SELALU draft**, `approvedBy` **SELALU null** — trust tidak pernah
  ikut file; baris `status:` di frontmatter hasil persist dipaksa `draft`
  agar restart tidak memuat status approved dari sumber tak terverifikasi.
- **Collision ditolak keras**: direktori tujuan yang sudah ada tidak pernah
  ditimpa (beda dengan import D5 yang merge LWW — install lokal gagal keras
  agar operator sadar).
- Path safety: slug tervalidasi (`^[a-z0-9][a-z0-9-]{0,63}$`) + target tetap
  di dalam direktori skills.
- Frontmatter hasil persist menyertakan `sha256:` (integritas untuk restart;
  parser mengabaikan kunci tak dikenal).
- `onChanged` (hot-reload registry) best-effort — gagal tidak menggagalkan
  install.

### 2. CLI (`apps/tiko/bin/tiko.dart`)

```
tiko skills install <path> [--sha256 <hex>]
```

Output: slug, status draft, sha256, sumber; ditutup pengingat alur approval
(`tiko skills approve <slug>`). Error → stderr + exit 1.

## Batasan (dilaporkan jujur)

- Tidak ada tanda tangan kriptografis / key signing — hanya checksum SHA-256
  yang diverifikasi terhadap nilai yang diberikan operator (cocok untuk
  transfer file terpercaya, bukan trust publik).
- Tidak ada registry server / resolusi `user/skill` dari jaringan (BLOCKED).
- Skill terpasang tetap draft — harus di-approve manual sebelum aktif penuh.

## Pengujian

`packages/agent_tools/test/skill_local_install_test.dart` — 9 test:
markdown (status dipaksa draft + sha256 dicatat), direktori, paket JSON D5,
verifikasi SHA-256 (lolos/mismatch fail-closed tanpa file tertulis),
collision anti-timpa, rahasia ditolak, sumber tidak valid, onChanged
best-effort, frontmatter sha256 tidak diduplikasi.

Bug nyata yang ditemukan test: berkas markdown tunggal memakai hint slug
dari nama file (`SKILL.md` → slug `skill`) — diperbaiki: hint hanya untuk
sumber direktori; markdown tunggal memakai slug frontmatter.

# GUI-P1-03: Skills Manager Flutter — 2026-11-18

Implementasi item **GUI-P1-03** (Skills Manager Flutter) dari backlog audit
gui (`TIKO-AGENT-GUI-REPORT.md` §11 P1): lifecycle skill — evaluate → approve →
active → rollback — plus feedback 👍/👎, semuanya lewat GUI, bukan command `/bot`/
CLI. Sumber data identik dengan web UI (`GET /v1/skills`), memakai repo API
skill runtime (`RuntimeSkillApi`) yang sudah tersedia di `agentd`.

## 1. Data layer (typed, GUI-P0-03 parity)

- `data/models.dart`: DTO baru —
  - `SkillItem` (slug/name/description/triggers/tools/version/status/uses/
    successes/positive/negative/golden/approvedBy + `feedbackAllowed` gate
    model: hanya trial/approved yang boleh diberi feedback, sesuai
    `RuntimeSkillApi.recordFeedback`) + `successRate`.
  - `SkillGateOutcome` (ok/slug/stage/findings/golden/message) — hasil
    evaluate/approve/rollback (`SkillGateResult`).
  - `SkillHistoryEntry` (action/actor/at/reason) — `SkillLedgerRecord`.
- `agent_api_client.dart`: `listSkills()`, `sendSkillFeedback()`,
  `evaluateSkill()`, `approveSkill()`, `rollbackSkill()`,
  `fetchSkillHistory()`. Catatan khusus: `RuntimeSkillApi` mengembalikan
  penolakan gate sebagai HTTP 200 dengan kunci `error` (bukan status HTTP);
  klien mengangkatnya menjadi `ApiError(invalidRequest, pesan gate)`.
- `data/agent_repository.dart`: `skills()`, `skillFeedback()` (→ `recorded`),
  `evaluateSkill()`, `approveSkill()`, `rollbackSkill()`, `skillHistory()` —
  semua DTO typed via `_guard` (network/timeout tetap ApiError).

## 2. UI (`ui/skills_view.dart`)

- `SkillsPage` (stateful): header `PageHeader` + refresh, filter teks
  slug/nama/status, daftar kartu skill.
- Kartu skill: status chip berwarna (approved=hijau, trial=biru,
  draft=kuning, retired=abu), metrik `uses / 👍 / 👎 / sukses%`, tombol
  feedback 👍/👎 yang **dinonaktifkan** (dengan tooltip alasan) untuk
  draft/retired — larangan audit: feedback tidak pernah mempromosikan skill.
- Menu lifecycle per skill: `Evaluate (scan + golden)` selalu, `Approve
  (promosikan)` untuk belum approved/retired, `Rollback ke draft` untuk
  approved — sesuai gate runtime (approve wajib lulus evaluasi ulang).
- Detail bottom sheet (tap kartu): deskripsi, triggers/tools, version,
  approved_by, metrik, dan **riwayat gate** dari ledger
  (`GET /v1/skills/{slug}/history`), row `eval_failed` ditandai.
- Hasil aksi ditampilkan sebagai SnackBar hijau/merah dengan stage/message.

## 3. Shell & refresh

- `app/app_routes.dart`: route `skills` baru (icon `auto_awesome`), non-primer
  di mobile (ikut More), rail desktop ikut dari peta yang sama.
- `shell/desktop_shell.dart`: rail kini dicadangkan tinggi intrinsik
  (`length * 80 + 48`); jika tinggi jendela lebih pendek, area rail dibungkus
  scroll — memperbaiki overflow RenderFlex saat destinasi bertambah banyak
  (semula 9 → kini 10 destinasi).
- `main.dart`: state `skills`; refreshAdmin menjadi **10 GET paralel**; case
  route `AppRoute.skills`; entri Skills baris-baru di `_MorePage` dengan
  callback repo lengkap; `_sendSkillFeedback` di shell mereset error admin lalu
  memicu refreshAdmin agar metrik baru tampil.

## 4. Test

- `test/skills_repository_test.dart` (8 test baru, fake agentd HTTP — file
  pure `test()`, bebas binding): DTO + metrics ledger, feedback POST body
  `positive`(bool) + path slug, penolakan gate draft (payload `error` 200 →
  ApiError invalidRequest), outcome evaluate ok / approve gagal-with-findings /
  rollback, riwayat gate, bearer tetap di header (bukan query).
- `test/skills_view_test.dart` (5 test baru): render chip status + metrik,
  feedback meneruskan slug+polaritas, feedback draft nonaktif, filter teks,
  aksi lifecycle approve memanggil callback + SnackBar hasil.
- `test/app_shell_test.dart`: kriteria route map diperbarui — 6 route
  non-primer (skills/tasks/memory/events/logs/settings) dikelompokkan ke More.

## Yang TIDAK termasuk (jujur)

- **CRUD skill (create/import/uninstall)**: gateway belum punya endpoint
  mutasi skill lain selain feedback/gate (`docs` audit §3.5; larangan menampilkan
  kontrol tanpa endpoint).
- **Skill hub browse / share package**: menunggu hub server (E-series blocked).
- **Live push skill events ke Flutter**: tetap polling 15 detik (belum ada WS
  global admin feed).

## Verifikasi

- Diverifikasi **lokal**: Flutter 3.47.9 — `flutter analyze` no issues;
  `flutter test` 129 test lulus (termasuk 13 test baru);
  `flutter build web --release` sukses.
- CI (jobs gate, dart, flutter, desktop, Android, audit supply-chain, CodeQL).

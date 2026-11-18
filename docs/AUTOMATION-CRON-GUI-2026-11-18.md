# GUI-P1-09: Automation / Cron CRUD — 2026-11-18

Item **GUI-P1-09** (Automation/Cron CRUD) dari backlog audit GUI: halaman
admin kini dapat **melakukan CRUD penuh** cron job scheduler daemon —
list, create, update (toggle ON/OFF + mutasi parsial), delete, dan
**run now** — dengan backend endpoint REST yang benar-benar ada
(`GET/POST /v1/jobs`, `PATCH/DELETE /v1/jobs/:id`,
`POST /v1/jobs/:id/run`). Tidak ada kontrol GUI yang ditampilkan tanpa
endpoint pendukung.

## 1. Scheduler (`packages/agent_scheduler`)

- `JobStore.update(id, {cron, prompt, channel, userKey, enabled,
  missedPolicy, timezone})` — mutasi parsial; `missed_policy` dinormalisasi
  case-insensitive (`run_once` → `runOnce`, `catch_up` → `catchUp`);
  perubahan `cron`/`timezone` menghitung ulang `next_run` via
  `CronExpression.nextAfter(now, timezone:)` dengan validasi IANA; claim
  lama (`pendingRunAt`/`scheduledAt`) dibuang saat jadwal berubah.
- `JobStore.runNow(id)` — majukan `next_run` ke sekarang sehingga tick
  scheduler berikutnya (≤ ~20 detik) mengklaim job; ditolak (null) bila job
  sedang delivery-pending atau masih punya claim aktif.
- Efek samping kecil yang ikut diperbaiki: `ScheduleJobTool` sebelumnya
  tidak pernah mencocokkan `run_once`/`catch_up` (normalisasi lama
  case-sensitive `replaceAll('_')` tanpa case-fold) sehingga `catch_up`
  diam-diam jatuh ke `runOnce` — kini dinormalisasi sama dengan GUI.
- Validasi konsisten dengan `add()`: cron parse 5 field, prompt 1..10000
  karakter, channel ≤64, user_key ≤256, `missed_policy` salah → `ArgumentError`,
  cron salah → `FormatException`.

## 2. Gateway (`packages/agent_gateway`)

- Callback baru: `jobsProvider`, `createJob`, `updateJob`, `deleteJob`,
  `runJobNow` — null → `501 not_implemented`.
- Routes: `GET /v1/jobs` (list `{jobs: [...]}`), `POST /v1/jobs`
  (create, 201), `PATCH /v1/jobs/:id` (mutasi parsial, 404 id asing),
  `DELETE /v1/jobs/:id`, `POST /v1/jobs/:id/run` (404 bila id asing atau
  job sedang busy).
- `_validateJobPayload`: allowlist field (`cron`, `prompt`, `channel`,
  `user_key`, `enabled`, `missed_policy`, `timezone`), unknown field 400;
  cron+prompt wajib saat create; panjang/tipe tiap field divalidasi;
  `missed_policy` hanya diterima `skip | run_once | runOnce | catch_up |
  catchUp`.

## 3. agentd wiring (`apps/agentd/bin/agentd.dart`)

- Callback tersambung langsung ke `rt.jobs` (JobStore durabel `jobs.json`):
  create memakai default channel `http`, user_key `admin`, timezone `UTC`,
  missed_policy `runOnce`; `FormatException`/`ArgumentError` dipetakan ke
  `400 invalid_request` (bukan 500 generik).
- Delivery/claim tidak diubah: run yang sedang berjalan atau sedang delivery
  tidak dapat di-run-now/di-hapus-diam-diam.

## 4. Flutter (`apps/agent_flutter`)

- DTO: `JobsSnapshot`/`JobInfo` (mirror payload, snake_case → camelCase).
- Klien + repo: `listJobs`, `createJob`, `updateJob`, `deleteJob`
  (false pada 404), `runJobNow` (null pada 404/busy).
- `ui/automation_view.dart` (`AutomationPage`): daftar job dengan badge
  ON/OFF, cron + timezone + missed_policy, channel/user, next/last run
  relatif waktu, badge delivery state; toggle Switch (PATCH enabled),
  tombol **Run now** (POST run + snackbar bila job busy), tombol Hapus
  dengan dialog konfirmasi; dialog create (cron + prompt + channel +
  timezone IANA); kartu penjelasan missed_policy.
- Route `AppRoute.automations` (rail "Automation", non-primary → kelompok
  More di mobile); `refreshAdmin` kini **16 GET paralel** (indeks 15 =
  `repo.jobs()`); More page mobile memuat ListTile Automation.

## 5. Web parity (`apps/agentd/web`)

- Tab **Automation**: daftar job (badge ON/OFF, meta delivery), tombol
  Run now / Aktifkan-Matikan (PATCH) / Hapus, form create cron + prompt +
  channel + timezone. Render aman `textContent` (XSS dicegah, diuji di
  harness). Test node harness +4 (17 total).

## 6. Dokumentasi & test

- Test: scheduler 4 baru (`job_store_crud_test.dart`), gateway 9 baru
  (`http_api_jobs_test.dart`), Flutter 13 baru (7 repository + 6 view),
  web 4 baru — `dart analyze`/`dart test` scheduler (44) & gateway (169),
  `flutter analyze` + `flutter test` 194 lulus, `flutter build web --release`
  sukses, `node --test` 17 lulus.
- Setiap endpoint GUI ini mencerminkan kemampuan tool `schedule_job`/
  `cancel_job` dan store durabel yang sudah ada dari awal.

## Yang TIDAK termasuk

- **Tidak ada** editor prompt/cron inline per baris di Flutter/web —
  mutasi `cron`/`prompt`/`timezone` tersedia lewat API (`PATCH`) dan sudah
  terverifikasi gateway, tapi UI edit form lengkap menyusul (toggle,
  run now, dan delete yang ada sudah real).
- **Tidak ada** riwayat eksekusi per job (timeline run sukses/gagal) —
  hanya `last_run` + `delivery_state`.
- **Tidak ada** impor/ekspor definisi job, duplikasi job, atau grouping
  per channel/user.
- **Tidak ada** penitipan secret per job — job berjalan dengan kredensial
  daemon yang sama (user_key hanyalah routing akses).
- Dashboard job dari `/v1/status` (`jobs: <jumlah>`) tetap angka agregat.

# GUI-P1-10: Security Center — 2026-11-18

Item **GUI-P1-10** (Security Center, perluasan backlog audit GUI setelah
GUI-P1-09): halaman admin kini punya **satu snapshot konsolidasi status
keamanan runtime** yang benar-benar disajikan backend
(`GET /v1/security`). Read-only penuh — tidak ada kontrol GUI yang
ditampilkan tanpa endpoint pendukung, dan tidak ada nilai rahasia yang
pernah keluar dari daemon.

## 1. Runtime (`packages/tiko_runtime` + `packages/agent_security`)

- `TokenAnomalyDetector.sampledSlugs` — getter daftar slug yang punya
  sampel baseline (diurutkan), sehingga Security Center bisa menampilkan
  statistik per-skill tanpa mengintip isi baseline.
- `TikoRuntime.securitySnapshot()` — konsolidasi read-only:
  - `safety`: `safe_mode`, `panic`, `stop_requested` (dari `SafetyState`).
  - `sandbox`: nama sandbox aktif (`landlock`/`none`/…).
  - `credentials`: flag `sealed_storage` saja (true saat passphrase
    tersedia) — flag, bukan nilai.
  - `plugins`: dari `pluginSnapshot()` — id, registered, pending,
    granted/requested count.
  - `token_anomaly`: enabled, `quarantines_today` (map harian
    `_tokenQuarantinesByDay`), `max_quarantines_per_day`, dan daftar
    `skills` (slug + jumlah sampel baseline).
  - `rate_anomaly`: window & max events dari `AnomalyDetector`.
  - `guard`: counter `blocked_turns`/`sanitized_turns` (in-memory,
    direset saat restart — diuji via `checkTokenAnomalyForTest`).
  - `audit`: `total_in_memory` + 15 entri terakhir (sudah teredaksi di
    `AuditLog.recent`).

## 2. Gateway (`packages/agent_gateway`)

- Callback baru `securityProvider` — null → `501 not_implemented`.
- Route `GET /v1/security` (auth bearer wajib; terdaftar sebelum blok
  `/v1/jobs`). Read-only: method lain → 404.

## 3. agentd wiring (`apps/agentd/bin/agentd.dart`)

- `securityProvider` menyambung `rt.securitySnapshot()` dan menambah
  `active_sessions` di wiring (bukan di runtime) karena
  `rt.sessions.list()` async — jumlah sesi aktif ikut dalam snapshot.

## 4. Flutter (`apps/agent_flutter`)

- DTO: `SecuritySnapshot`/`SecurityPluginItem`/`SkillTokenStat`
  (mirror payload, snake_case → camelCase, toleran field kosong).
- Klien + repo: `fetchSecurity` (`GET /v1/security`, timeout 10s) dan
  `repo.security()`.
- `ui/security_view.dart` (`SecurityPage`): kartu **Safety** (pill safe
  mode ON/OFF, PANIC, stop request, sandbox kind, sealed storage, sesi
  aktif), **Token anomaly (E1)** (status detektor, kuota karantina, baseline
  per skill), **Plugin & consent** (per plugin: granted/menunggu/tidak
  terdaftar), **Guard & rate** (turn diblokir/disanitasi, threshold rate),
  **Audit terakhir** (total + 15 entri ts/tool/risk/verdict/session).
- Route `AppRoute.security` (rail "Security", ikon security_outlined,
  non-primary → kelompok More di mobile); `refreshAdmin` kini **17 GET
  paralel**; More page mobile memuat ListTile Security dengan subtitle
  status.

## 5. Web parity (`apps/agentd/web`)

- Tab **Security**: list 5 kartu (Safety dengan pill status, Token
  anomaly, Plugin & consent, Guard & rate, Audit terakhir) + kartu
  batasan. Render aman `textContent` (XSS dicegah). Tombol refresh
  tersendiri. Test node harness +2 (19 total).

## 6. Dokumentasi & test

- Test: gateway 4 baru (`http_api_security_test.dart` — snapshot
  konsolidasi, 401 tanpa auth, 501 bare daemon, POST read-only 404),
  runtime 3 baru (`security_snapshot_test.dart`), Flutter 11 baru (4
  repository + 7 view), web 2 baru.
- Verifikasi: `dart analyze` agent_security/tiko_runtime/agent_gateway/
  agentd bersih; `dart test` gateway 173, agent_security 97,
  tiko_runtime 257, agentd 7 — semua lulus; `flutter analyze` bersih,
  `flutter test` 205 lulus, `flutter build web --release` sukses,
  `node --test` 19 lulus.

## Yang TIDAK termasuk

- **Read-only** — TIDAK ada toggle safe mode, panic, stop request, atau
  kill switch dari GUI. Perubahan state keselamatan tetap lewat
  tool/operator daemon, bukan UI.
- **TIDAK ada** manajemen consent aktif di sini (grant/revoke per plugin
  tetap di tab Plugin yang sudah ada); Security Center hanya menampilkan
  ringkasannya.
- **TIDAK ada** detail izin per plugin (daftar permission granularity)
  — hanya jumlah granted/requested.
- **TIDAK ada** izin sandbox/secret apapun: `sealed_storage` hanya flag
  boolean, passphrase/token tidak pernah keluar daemon.
- Counter guard (`blocked_turns`/`sanitized_turns`) in-memory dan **reset
  saat daemon restart**; tidak dipersist.
- Audit terbatas **15 entri terakhir** dari ring buffer in-memory
  (maks 1000) yang sudah teredaksi — bukan query browser penuh dengan
  filter (audit search penuh = item backlog terpisah).
- Statistik token anomaly menampilkan jumlah sampel, bukan nilai
  baseline mean/stddev (data internal detektor tetap di runtime).

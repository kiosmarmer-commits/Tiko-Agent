# GUI-P1-05: Provider & Model Manager Flutter — 2026-11-18

Implementasi item **GUI-P1-05** (Provider & Model Manager) dari backlog audit
GUI (`TIKO-AGENT-GUI-REPORT.md` §11 P1): daftar provider chat + health
circuit breaker, mapping tier router, dan pergantian provider per sesi
(parity command `/model`) lewat REST API + GUI Flutter, tanpa harus mengetik
command di chat.

## 1. Backend REST API (baru)

- `packages/tiko_runtime/lib/src/tiko_runtime.dart`: accessor/method baru di
  atas router yang sama dengan `/model`:
  - `defaultProviderId`, `providerIds()`, `sessionModelOverrides()`.
  - `effectiveSessionProvider(sessionId)` — override `/model` → default
    router → provider id pertama (sorted); null bila tanpa provider.
  - `setSessionProvider(sessionId, providerId)` — mirror `/model <id>`
    (validasi provider dikenal + event `model.switched`).
  - `clearSessionProvider(sessionId)` — mirror `/model default`.
- `packages/agent_gateway/lib/src/http_api.dart` (GUI-P1-05):
  - 2 callback opsional: `providersProvider`, `sessionProviderSetter`
    (null → `501 not_implemented`).
  - `GET /v1/providers` → snapshot:
    `{default, providers: [{id, capabilities: {tool_calling, vision,
    streaming, max_context}, health: {failures, successes, open, phase,
    last_error, last_latency_ms}}], tiers: {tier: provider},
    session_overrides: {session: provider}}`.
  - `POST /v1/providers/session` body `{session_id, provider}` →
    `{ok: true, session_id, provider}`; `provider: "default"` melepas
    override; provider tidak dikenal → `404 not_found`; body tidak lengkap →
    `400 invalid_request`.
- `apps/agentd/bin/agentd.dart`: pasang kedua callback di atas `rt` —
  capabilities per provider dari `rt.providerById(id).capabilities`, health
  dari `rt.providerHealth()`, tier dari `rt.config.tierProviders`, override
  setter memakai `rt.setSessionProvider`/`rt.clearSessionProvider`.

## 2. Data layer Flutter (typed)

- `data/models.dart`: DTO `ProvidersSnapshot` (defaultId/providers/tiers/
  sessionOverrides), `ProviderItem` (id + capabilities + `ProviderHealthInfo`)
  — semua `fromMap` snake_case.
- `agent_api_client.dart`: `fetchProviders()` (GET) dan
  `setSessionProvider(sessionId, providerArg)` (POST; false bila 400+).
- `data/agent_repository.dart`: `providers()` → `ProvidersSnapshot` dan
  `setSessionProvider()` — typed via `_guard`.

## 3. UI (`ui/provider_manager_view.dart`)

- `ProviderManagerPage` (stateful): header + tombol **+** (set override) +
  refresh.
- Kartu per provider: id, badge `default`, chip fase health berwarna
  (closed=hijau, half_open=kuning, open=merah, unknown=abu), capabilities
  (tools/vision/streaming/context), metrik breaker (sukses/gagal/latensi) dan
  error terakhir bila ada.
- Kartu Tier routing: pemetaan `tier N → provider` dari config router.
- Kartu Override sesi: daftar sesi ber-override dengan tombol
  **Reset default** (`provider: "default"`).
- Dialog set override: field Session id (terisi otomatis bila dibuka dari
  ActionChip "Sesi yang bisa di-override") + dropdown provider
  (`default (id)` + semua provider id). Tidak ada field untuk mengubah
  default global — config immutable saat runtime (lihat "Yang TIDAK
  termasuk").
- Hasil aksi SnackBar hijau/merah (messenger & warna di-capture sebelum
  await).

## 4. Shell & refresh

- `app/app_routes.dart`: route `providers` baru (icon `route`), non-primer
  di mobile (ikut More); rail desktop kini 12 destinasi (scroll guard tetap).
- `main.dart`: state `providerSnapshot`; refreshAdmin menjadi **13 GET
  paralel**; case route `AppRoute.providers` dengan callback
  `onSetSessionProvider` (sukses → refreshAdmin force); `_MorePage` menerima
  `providers`/`availableSessions` + ListTile Providers dengan callback repo.

## 5. Test

- `packages/agent_gateway/test/http_api_providers_test.dart` (7 test):
  snapshot lengkap, 401, POST override, POST `default` melepas override,
  provider tidak dikenal 404, body tidak lengkap 400, tanpa callback 501.
- `apps/agent_flutter/test/providers_repository_test.dart` (6 test, fake
  agentd, pure `test()`): DTO typed (capabilities + health + tiers +
  overrides), POST body, `default` melepas override, provider tidak dikenal
  → false, bearer di header, 501 → ApiError(notImplemented).
- `apps/agent_flutter/test/providers_view_test.dart` (5 testWidgets):
  render chip health/tier/override/error, kondisi snapshot null, refresh
  callback, dialog override mengirim session+provider, reset default
  callback.
- `test/app_shell_test.dart`: set route non-primer diperbarui +providers
  (kini 8 route dikelompokkan ke More).

## Yang TIDAK termasuk (jujur)

- **Mengubah provider default global runtime**: config router immutable saat
  daemon hidup (ubah via config file + restart) — GUI hanya menampilkan
  default dan mengubah override per sesi, sama seperti command `/model`.
- **Melihat/override provider per bot**: bot punya field `model` sendiri
  (GUI-P1-04 edit dialog) — tidak diduplikasi di sini.
- **Live push health breaker**: health di-refresh saat polling admin 15
  detik; belum ada WS global admin feed.
- **Web UI parity**: halaman Providers belum ada di `apps/web` (menyusul).
- **Fitur tier routing editor**: mapping tier read-only.

## Verifikasi

- Diverifikasi **lokal**:
  - `packages/agent_gateway`: `dart analyze` no issues; `dart test` 148
    lulus (7 test baru).
  - `packages/tiko_runtime`: `dart test` 254 lulus; `apps/agentd`: 7 lulus.
  - `apps/agent_flutter`: `flutter analyze` no issues; `flutter test` 156
    lulus (11 test baru); `flutter build web --release` sukses.
- CI: gateway test job, flutter analyze/test/build web, desktop, Android,
  audit supply-chain, CodeQL.

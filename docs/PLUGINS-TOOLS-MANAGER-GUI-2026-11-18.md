# GUI-P1-06: Plugin & Tools Manager Flutter — 2026-11-18

Implementasi item **GUI-P1-06** (MCP/Plugin/Tools Manager) dari backlog audit
GUI (`TIKO-AGENT-GUI-REPORT.md` §11 P1): status plugin + capability consent
(setujui/cabut, parity command `/plugin consent`), katalog tool registry host,
dan status server MCP — lewat REST API + GUI Flutter, tanpa harus mengetik
command di chat. Prinsip yang sama dengan milestone sebelumnya: **setiap
kontrol GUI hanya muncul karena endpoint backend-nya benar-benar ada**.

## 1. Backend REST API (baru)

- `packages/tiko_runtime/lib/src/tiko_runtime.dart` — accessor/method publik
  baru di atas state yang sama dengan command `/plugin`:
  - `pluginSnapshot()` — daftar plugin (terdaftar + menunggu consent),
    grant tersimpan (`pluginConsents`), permintaan permission pending
    (`_pendingPlugins`), dan 10 event hook terakhir dari `PluginRegistry`.
  - `toolCatalog()` — katalog tool dari `ToolRegistry.specs`
    (name/description/risk/timeout/parallel_safe, sorted by name).
  - `mcpSnapshot()` — konfigurasi server MCP dari config immutable +
    hasil loader (`McpToolLoader.statuses`: ready/disabled/failed/invalid
    + detail + jumlah tool) + flag `started`.
  - `grantPluginConsent(name)` / `revokePluginConsent(name)` — logika persis
    branch `grant`/`revoke` dari command `/plugin consent` (simpan grant,
    registrasikan pending plugin + daftarkan tool deklarasinya; revoke
    cabut grant + unregister). Mengembalikan record `({bool ok, String
    message})`.
  - Command `/plugin consent` **direfaktor mendelegasikan** ke dua method
    di atas — satu sumber kebenaran untuk CLI dan REST.
- `packages/agent_gateway/lib/src/http_api.dart`:
  - 2 callback opsional baru: `pluginProvider`, `pluginConsentSetter`
    (null → `501 not_implemented`).
  - `GET /v1/plugins` → snapshot lengkap:
    `{plugins: [{id, registered, pending, granted, requested}],
    events: [{plugin, hook, detail, error, at}],
    tools: [{name, description, risk, timeout_sec, parallel_safe}],
    mcp: {started, configured: [...], loader: [...]}}`.
  - `POST /v1/plugins/consent` body `{plugin, action: grant|revoke}` →
    `{ok: true, message}`; plugin tidak dikenal / tidak menunggu consent →
    `404 not_found` (pesan server diteruskan); plugin kosong >64 char atau
    action di luar grant/revoke → `400 invalid_request`.
- `apps/agentd/bin/agentd.dart`: pasang kedua callback di atas `rt` —
  snapshot menggabungkan `rt.pluginSnapshot()` + `rt.toolCatalog()` +
  `rt.mcpSnapshot()`; consent setter memanggil
  `rt.grantPluginConsent`/`rt.revokePluginConsent`.

## 2. Data layer Flutter (typed)

- `data/models.dart`: DTO `PluginsToolsSnapshot` (plugins/tools/events/mcp),
  `PluginItem` (id/registered/pending/granted/requested), `ToolInfo`
  (name/description/risk/timeoutSec/parallelSafe), `PluginEventInfo`,
  `McpStatusInfo` (started/configured/loader), `McpServerInfo`
  (id/type/enabled/risk/command/allow) — semua `fromMap` snake_case dan
  toleran terhadap field yang hilang.
- `agent_api_client.dart`: `fetchPlugins()` (GET, `_throwIf`) dan
  `setPluginConsent(plugin, action)` (POST; 404/400 dilempar sebagai
  `ApiError` typed dengan pesan server).
- `data/agent_repository.dart`: abstract + impl `pluginsTools()` (→
  `PluginsToolsSnapshot`) dan `setPluginConsent()` (→ pesan server).

## 3. UI Flutter

- `ui/plugin_manager_view.dart` (baru): `PluginManagerPage` stateful —
  `PageHeader` (subtitle N plugin + pending + tools + server MCP) + tombol
  refresh; `_PluginCard` (badge status berwarna: terdaftar hijau / menunggu
  consent amber / tidak aktif abu; chip permission granted hijau dan
  `diminta·<perm>` amber; tombol **Setujui** untuk pending dan **Cabut
  consent** untuk terdaftar); `_SectionCard` "Tools terdaftar" (baris dense
  per tool + `_RiskBadge` low/medium/critical); "Server MCP" (per server:
  id + transport, chip status loader berwarna ready/failed/disabled/unknown,
  risk, jumlah tool, detail); "Event plugin terakhir" (10 terakhir, error
  merah). SnackBar hijau/merah dengan messenger + warna di-capture sebelum
  await (aman dari `use_build_context_synchronously`).
- `app/app_routes.dart`: `AppRoute.plugins` ('Plugins',
  `Icons.extension_outlined`, non-primer) — rail kini 13 destinasi.
- `main.dart`: state `pluginSnapshot`; refreshAdmin kini **14 GET** paralel
  (index 13 = pluginsTools); case `AppRoute.plugins` dengan `onConsent`
  (sukses → snackbar pesan server + `refreshAdmin(force: true)`); `_MorePage`
  field `pluginSnapshot` + ListTile Plugins dengan counter.

## 4. Test

- `packages/agent_gateway/test/http_api_plugins_test.dart` (8 test):
  snapshot lengkap (plugins + tools + mcp + events), 401 tanpa auth, grant
  pending plugin, revoke terdaftar, 404 plugin tidak dikenal, 404 plugin
  tanpa pending, 400 body invalid (plugin & action), 501 tanpa callback.
- `apps/agent_flutter/test/plugins_repository_test.dart` (5 test): parse
  snapshot typed, POST body consent, pesan revoke, `ApiError.notFound`,
  bearer header.
- `test/plugins_view_test.dart` (5 testWidgets): render plugin + badge +
  chips, katalog tool + risk + MCP, kondisi kosong, tombol Setujui →
  callback grant + snackbar, tombol Cabut → callback revoke.
- `test/app_shell_test.dart`: set `grouped` + `AppRoute.plugins`.

## Yang TIDAK termasuk (jujur)

- **Menambah/mengedit konfigurasi plugin & server MCP dari GUI**: config
  (`plugins.process` dan `mcp`) immutable saat daemon hidup (ubah via
  config file + restart). GUI hanya menampilkan konfigurasi dan statusnya;
  satu-satunya mutasi runtime adalah consent grant/revoke — sama seperti
  command `/plugin`.
- **Upload/install/uninstall plugin** dari GUI (tidak ada mekanisme runtime).
- **Status per hook detail plugin process** (stdin/out latency): hanya event
  10 terakhir yang kena-dapoq, bukan stream penuh.
- **Live push status plugin/MCP**: di-refresh saat polling admin 15 detik;
  belum ada WS global admin feed.
- **Web UI parity**: halaman Plugins belum ada di `apps/web` (menyusul).

## Verifikasi

- Diverifikasi **lokal**:
  - `packages/agent_gateway`: `dart analyze` no issues; `dart test` 156
    lulus (8 test baru).
  - `packages/tiko_runtime`: `dart test` 254 lulus (refactor `/plugin
    consent` tidak mengubah perilaku CLI); `apps/agentd`: `dart analyze` no
    issues.
  - `apps/agent_flutter`: `flutter analyze` no issues; `flutter test` 166
    lulus (10 test baru); `flutter build web --release` sukses.
- Batas: seperti dijelaskan, kontrol GUI memakai endpoint yang benar-benar
  terekspos (`GET /v1/plugins`, `POST /v1/plugins/consent`); tidak ada
  kontrol untuk aksi yang belum punya backend.

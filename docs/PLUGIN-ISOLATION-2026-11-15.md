# Plugin Isolation — Capability Consent + Proses Terpisah — 15 November 2026

Plugin isolation (rekomendasi #5 dari sesi Hermes-parity): hardening sistem plugin terhadap plugin pihak ketiga yang tidak terpercaya, dengan dua lapis pertahanan:

1. **Capability consent (fail-closed)** — permission yang diminta plugin hanya aktif setelah persetujuan eksplisit administrator; yang belum ditanyakan dianggap ditolak.
2. **Isolasi proses out-of-process** — plugin pihak ketiga berjalan sebagai proses OS terpisah; crash/hang plugin tidak menggagalkan agent loop maupun merusak memori host.

Rujukan riset: defense-in-depth untuk tool/plugin tidak terpercaya (tool poisoning, indirect prompt injection via output plugin), arsitektur plugin out-of-process (protokol JSON line-based ala LSP/MCP stdio), dan capability-based security (enforcement di execution layer, bukan hanya manifest).

## Desain

### `PluginConsentStore` (`packages/agent_core/lib/src/plugin_consent.dart`)

- Store persisten JSON di `<dataDir>/plugins/consents.json`; tulis atomik (tmp+rename), map terurut.
- `allGranted(plugin, permissions)` **fail-closed**: `false` bila plugin belum pernah disetujui atau ada satu saja permission yang belum di-grant.
- `grant`/`revoke` (per permission atau seluruh plugin), `hasAnyGrant`, `grantsOf`.
- File korup (`FormatException`) ditoleransi — store dimulai kosong, tidak menggagalkan startup.

### `ProcessPlugin` (`packages/agent_core/lib/src/plugin_process.dart`)

- `Plugin` yang men-spawn proses OS (`Process.start(command, args)`) dan berkomunikasi lewat stdin/stdout dengan **protokol JSON per baris**:
  - host → child: `{"op":"hello","name":...}` saat init, lalu `{"op":"hook","hook":"<nama>","input":...}` per panggilan hook.
  - child → host: `{"ok":true}` untuk hello; untuk `beforeToolCall`: `{"verdict":"allow"}` / `{"verdict":"deny","reason":...}` / `{"verdict":"modify","args":{...}}`; hook lain `{"ok":true}`.
- **Timeout per hook** (default 10s) — child yang hang melempar `StateError`, tidak menggantung agent loop.
- **Crash containment** — child yang keluar menandai plugin dead; hook berikutnya melempar `StateError` yang dicatat registry sebagai `PluginEvent` (loop tetap jalan). `dispose()` meng-kill child.
- Mendukung semua hook lifecycle: `beforeToolCall`, `afterToolCall`, `onSessionStart`, `onSessionEnd`, `onMessage`.

### Consent gate di `PluginRegistry` (`packages/agent_core/lib/src/plugin_system.dart`)

- `consentGuard` opsional: `bool Function(String pluginName, Iterable<String> requestedPermissions)`.
- `register()` kini mengembalikan `Future<bool>` + parameter `requestedPermissions`; guard menolak → plugin **tidak** di-`init()` (tidak di-spawn) dan penolakan dicatat sebagai `PluginEvent` detail `consent denied`.
- Permission kosong = tidak ada yang perlu disetujui (auto-allow di level guard).

### Config `plugins.process` (`packages/tiko_runtime/lib/src/tiko_config.dart`)

```yaml
plugins:
  process:
    - name: contoh
      command: /usr/bin/dart
      args: ["path/plugin.dart", "normal"]
      permissions: [tools.read]
```

Validasi fail-closed: nama wajib `^[a-z][a-z0-9-]{1,63}$`, command non-kosong, permission harus salah satu dari `tools.read | tools.execute | memory.read | memory.write | network.fetch | sessions.read` — pelanggaran menjadi `ConfigIssue`, entri dilewati.

### Slash command `/plugin` (intercepted di funnel `chatWithStatus`)

| Perintah | Efek |
|---|---|
| `/plugin` atau `/plugin list` | plugin terdaftar + menunggu consent + grant tersimpan |
| `/plugin info <nama>` | status, consent, permission diminta |
| `/plugin consent <nama> grant` | setujui → plugin pending langsung didaftarkan (di-spawn) |
| `/plugin consent <nama> revoke` | cabut → consent dihapus + plugin dibatalkan registrasinya |

Event tambahan: `plugin.registered`, `plugin.consent.required`, `plugin.consent.granted`, `plugin.consent.revoked`.

### Alur startup

Plugin dari config yang belum disetujui **tidak error saat startup** — masuk antrean pending dan diumumkan lewat event `plugin.consent.required`; `/plugin list` menampilkannya sebagai `[menunggu consent: ...]`. Consent bersifat persisten: setelah grant, plugin tetap terdaftar lintas restart runtime.

## Keputusan desain

1. **Consent fail-closed** — default-deny; permission yang belum ditanyakan tidak pernah aktif diam-diam.
2. **Plugin pending tidak di-spawn** — guard dicek sebelum `init()`, sehingga kode plugin yang belum disetujui tidak pernah dieksekusi.
3. **`ProcessPlugin` di `agent_core`** — `agent_core` sudah bergantung pada `dart:io`, dan `agent_flutter` tidak bergantung pada `agent_core`, jadi tidak ada dependensi baru yang bocor ke UI.
4. **Isolasi proses, bukan isolasi manifest saja** — manifest/policy perlu tapi tidak cukup; enforcement capability terjadi di execution layer (registry) dan containment crash/hang di proses OS.
5. **Isolasi subagent tetap terpisah** — `spawn_subagent` + cancellation chaining (ALG-04/P1-09) sudah ada sebelumnya; fitur ini menambah dimensi isolasi untuk plugin pihak ketiga.

## Test

- `packages/agent_core/test/plugin_consent_test.dart` (5 test): fail-closed, grant+persist+reload, revoke, integrasi `consentGuard` (ditolak → `PluginEvent consent denied` → diterima setelah grant), permission kosong auto-allow.
- `packages/agent_core/test/plugin_process_test.dart` (3 test, fixture `test/fixtures/line_plugin.dart` mode `normal|hang|crash`): handshake + verdict deny/allow, hook timeout → `StateError`, crash → dead → hook berikutnya `StateError`.
- `packages/tiko_runtime/test/plugin_consent_commands_test.dart` (4 test e2e): pending tanpa consent (tidak di-spawn), grant→terdaftar→revoke, consent persisten lintas restart, aksi tidak dikenal ditolak.

## Batasan

- Protokol line-plugin belum mendukung streaming tool result atau tool baru yang didefinisikan plugin (plugin hanya observator/veto hook yang ada).
- Belum ada sandbox OS tambahan (seccomp/containers) di atas isolasi proses; containment saat ini adalah crash/hang containment + consent capability.

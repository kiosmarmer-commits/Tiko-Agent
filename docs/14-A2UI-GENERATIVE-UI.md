# Fase E — Rancangan Implementasi A2UI (Generative UI) untuk Tiko-Agent

**Status:** Desain (belum diimplementasikan). Dokumen ini adalah cetak biru lengkap untuk Fase E.

**Terakhir diperbarui:** November 2026 (setelah merge PR #146 / Fase D).

---

## Daftar isi

1. [Ringkasan eksekutif & keputusan](#1-ringkasan-eksekutif--keputusan)
2. [Apa itu A2UI (riset)](#2-apa-itu-a2ui-riset)
3. [Peta kondisi Tiko saat ini (hasil audit kode)](#3-peta-kondisi-tiko-saat-ini-hasil-audit-kode)
4. [Prinsip rancangan](#4-prinsip-rancangan)
5. [Arsitektur target (schematic)](#5-arsitektur-target-schematic)
6. [Apa yang DIUBAH](#6-apa-yang-diubah)
7. [Apa yang TIDAK DIRUBAH (jaminan)](#7-apa-yang-tidak-dirubah-jaminan)
8. [Skema pesan & kontrak JSON](#8-skema-pesan--kontrak-json)
9. [Desain UI & UX per permukaan](#9-desain-ui--ux-per-permukaan)
10. [Fitur diferensiasi: yang Tiko punya tapi AI agent lain belum ada](#10-fitur-diferensiasi-yang-tiko-punya-tapi-ai-agent-lain-belum-ada)
11. [Strategi anti-konflik & adaptasi perubahan API](#11-strategi-anti-konflik--adaptasi-perubahan-api)
12. [Keamanan](#12-keamanan)
13. [Rencana implementasi bertahap E1–E5](#13-rencana-implementasi-bertahap-e1e5)
14. [Inventaris uji](#14-inventaris-uji)
15. [Matriks kompatibilitas & fallback](#15-matriks-kompatibilitas--fallback)
16. [Lampiran: contoh end-to-end](#16-lampiran-contoh-end-to-end)

---

## 1. Ringkasan eksekutif & keputusan

**Masalah:** Tiko sudah punya generative-UI versi mini sendiri (grammar `genui` tertutup: `section, text, metric, chart, form, actions, divider`) yang berjalan end-to-end: tool `render_ui` → parser `GenUiSpec` → transport blok fence ` ```genui ` → renderer Flutter `GenUiView`. Namun vocabulary-nya kecil (7 tipe, tanpa gambar/tab/checkbox/slider), hanya hidup di chat, dan tidak ada negosiasi kapabilitas.

**Standar eksternal:** A2UI (github.com/a2ui-project/a2ui, Apache-2.0, project Google labs) adalah framework generative-UI open source: UI dikirim agen sebagai **data bukan kode**, lewat protokol streaming (JSONL/SSE) dengan skema ketat, dirender native (React/Angular/Lit/**Flutter**/SwiftUI/Compose). Filosofinya identik dengan yang sudah Tiko pakai.

**Keputusan:** **Opsi hibrida (evolusi bertahap), bukan penggantian total.**

- Protokol A2UI **v1.0** diadopsi sebagai format target untuk permukaan UI baru (channel `surface`).
- Grammar `genui` lama **tetap didukung penuh** (backward compatible, tidak dihapus).
- Semua interaksi dengan paket `a2ui_flutter` dibungkus **adapter** (anti-corruption layer) supaya perubahan API A2UI (masih pre-1.0) tidak merembes ke kode Tiko.
- Renderer A2UI dipakai di chat **dan** di semua halaman GUI (bot manager, kanban, automation, teams, MCP, approvals) lewat satu widget: `TikoSurfaceView`.

**Hasil yang dituju:** agen AI (model) dapat *menghasilkan UI mandiri* — kartu status, form input, tabel, chart, wizard, approval sheet — yang muncul di chat maupun halaman GUI lain, dengan keamanan fail-closed, tanpa menjalankan kode arbitrer, dan tetap jalan di semua platform Flutter (web/desktop/Android/mobile) plus fallback teks di gateway non-Flutter (Telegram/Discord/SMTP/Matrix).

---

## 2. Apa itu A2UI (riset)

### 2.1 Model protokol (v1.0)

| Pesan client→server / server→client | Isi |
|---|---|
| `createSurface` | Membuat permukaan baru; **tepat satu** komponen dengan id `root`. |
| `updateComponents` | Daftar datar (flat) komponen; tiap komponen menunjuk children **per id** (bukan nesting). |
| `dataModelUpdate` | Data terpisah dari struktur; komponen membaca data via binding/ekspresi. |
| `deleteSurface` | Menghapus permukaan. |

- Negosiasi katalog: dokumen JSON Schema dengan `$id` + `catalogId`; renderer hanya merender komponen yang dikenal katalognya → **kapabilitas eksplisit**.
- Delivery: **ordered & reliable** (cocok dengan WS frame Tiko yang sudah berurutan).
- Legacy (v0.8/v0.9: `beginRendering`, `surfaceUpdate`, buffer-until-begin) **tidak diadopsi** — Tiko langsung ke v1.0.

### 2.2 Paket Dart di pub.dev

| Paket | Peran | Catatan versi |
|---|---|---|
| `a2ui_core` | `MessageProcessor`, `SurfaceModel`, binding, ekspresi, `onSurfaceCreated/onAction/onError`, outbound listener | Murni Dart, tanpa Flutter |
| `a2ui_flutter` | `A2uiSurface` widget, `A2uiMarkdown`, katalog `basicCatalog()` (Material), API komponen kustom | 0.4.0; mendukung v1.0 + v0.9; dependensi `video_player`, `path_parsing` |
| `a2ui_agent` | `A2uiGenerator` (system prompt untuk mengajari model), `ResponseStream` (parse balasan model jadi pesan protokol saat streaming) | pola yang akan kita tiru tanpa dependensinya |
| `@a2ui/catalog-mcp` (Node) | Render hasil tool jadi A2UI untuk klien MCP | konsep dipinjam untuk MCP-in-Tiko |

### 2.3 Katalog dasar `a2ui_flutter`

Row, Column, List, Card, Tabs, Modal, Divider; Text (markdown via `A2uiMarkdown`), Image, Icon, Video, AudioPlayer; Button, TextField, CheckBox, ChoicePicker, Slider, DateTimeInput. Komponen kustom: `ComponentImplementation` + `CatalogImplementation`, props dinamis via `CommonSchemasV1`, action via `$ref common_types.json#/$defs/Action`; state anak dipertahankan dengan `KeyedSubtree(key: NodeKey(child.instanceId))`.

### 2.4 Model keamanan A2UI

- **Agen tidak tepercaya**: semua UI hanyalah data yang divalidasi skema; tidak ada kode yang dieksekusi.
- `openUrl` **butuh callback eksplisit dari host** (mis. url_launcher) — default tidak ada.
- Validasi input lewat `checks` (severity `warning`/`info`).
- Atribut aksesibilitas dipetakan ke Semantics/ARIA.

---

## 3. Peta kondisi Tiko saat ini (hasil audit kode)

Semua path berikut telah diverifikasi langsung di source (commit `244a81c`):

| Lapisan | Lokasi | Kondisi |
|---|---|---|
| Aturan masukan (aturan + batas) | `packages/agent_core/lib/src/genui.dart` — `GenUiSpec.parse`, `extractGenUiBlocks`, `splitGenUiSegments`; batas: depth 8, 100 node, teks 2000 char, 31 titik chart, 8 field, 16 opsi, 4 tombol, 20 children, **4 blok/pesan** | ✅ fail-closed, tanpa dependensi Flutter |
| Ekspor (tool) | `packages/agent_tools/lib/src/render_ui_tool.dart` → `RenderUiTool`; terdaftar `packages/tiko_runtime/lib/src/tiko_runtime.dart:896` | ✅ `render_ui` sudah bisa dipanggil model |
| Standar transport (transport) | Blok fence ` ```genui ` di teks chat (`extractGenUiBlocks`; dipakai `apps/agentd/bin/agentd.dart:690,729`) | ✅ tanpa perubahan protokol |
| Perender (renderer) | `apps/tiko_widgets/lib/src/gen_ui_view.dart` — `GenUiMessageView`/`GenUiView`; dipakai `apps/agent_flutter/lib/main.dart:1460` | ✅ chat web/desktop/mobile sudah merender widget |
| Aksi pengguna → agen | `chat_controller.dart:245 sendUiAction` → `POST /v1/ui/actions` (`apps/agent_gateway/lib/src/http_api.dart:1690`, runtime bindable) | ✅ loop interaktif utuh |
| Streaming | WS `broadcast({'type':'event', event})` (`http_api.dart:1079`) + frame `chat.status`/`chat.toolStart`/`chat.tool`/`cancel` (Chat-UX C4) | ✅ berurutan & reliable |
| Halaman GUI | `apps/agent_flutter/lib/ui/`: `bot_manager_view.dart`, `tasks_view.dart` (Kanban), `automation_view.dart`, `runs_page.dart`, `skills_view.dart`, `security_view.dart` | ⚠️ UI statik, belum menerima surface dari agen |

**Kesimpulan audit:** Tiko = "mini A2UI". Pemetaan komponen hampir 1:1 (`section`→Card/Column, `text`→Text, `metric`→Card+Text, `chart`→chart katalog, `form`→TextField/CheckBox/Slider, `actions`→Button, `divider`→Divider). Migrasi = **superset**, bukan rewrite.

---

## 4. Prinsip rancangan

1. **Adapter, bukan infeksi.** Semua tipe/API dari `a2ui_core`/`a2ui_flutter` hanya boleh disentuh di satu paket jembatan (`apps/tiko_widgets/lib/src/a2ui/`). Paket lain (`agent_core`, `agent_gateway`, `tiko_runtime`) **tidak** mengimpor A2UI sama sekali.
2. **Fail-closed seperti biasa.** Surface tidak valid → dirender sebagai pesan error merah + tetap tersimpan, tidak pernah crash, tidak pernah merender setengah jadi.
3. **Tidak ada perubahan protokol pesan lama (breaking legacy protocol change).** Klien/curl/skrip yang mengandalkan ` ```genui ` tetap bekerja 100%.
4. **UI = data, tindakan = approval.** Tidak ada komponen yang bisa memicu perintah sistem langsung; semua tombol mengalir ke pipeline `approvals`/tool risk yang sudah ada.
5. **Budget eksplisit di tiap lapisan.** Parser (agent_core), transport (WS), perender ( Flutter) masing-masing punya batas independen; pelanggaran terparah yang dipakai.
6. **Dua bahasa di transport, satu tampak (renderer).** `genui` dan `surface` hidup berdampingan; pengguna hanya melihat render terbaik yang tersedia.

---

## 5. Arsitektur target (schematic)

### 5.1 Aliran data end-to-end

```
                         ┌────────────────────────────────────────────────┐
  Model (provider AI)    │  turn agent: memilih tool render_a2ui /        │
  Gemini/OpenAI/...,     │  atau menulis blok fence ```a2ui di teks       │
  ollama_native, mock    └───────────────┬────────────────────────────────┘
                                          │
             ┌────────────────────────────▼─────────────────────────────┐
             │ tiko_runtime                                             │
             │  A2uiToolBridge (baru, part tiko_runtime.dart)           │
             │   - validasi pesan v1.0 (agent_a2ui.dart, agent_core)    │
             │   - surfaceId = 's-' + sessionId kecil + counter         │
             │   - event bus: surface.created / surface.updated         │
             │   - surface store: data/surfaces/<sessionId>/<id>.json   │
             │     (atomik tmp+rename, TTL + LRU)                       │
             └───────────────┬───────────────────────┬──────────────────┘
                             │                       │
        blok fence di teks   │                       │  event/WS
     (klien non-Flutter)     ▼                       ▼
   ┌─────────────────────────────┐   ┌──────────────────────────────────┐
   │ agent_gateway               │   │ agent_gateway HttpApiServer      │
   │ Telegram/Discord/SMTP/...   │   │  WS: frame {'type':'surface',    │
   │ fallback: teks + tombol     │   │        'payload': <A2uiMessage>} │
   │ teks dari renderer fallback │   │  HTTP /v1/surfaces (list/get)    │
   └─────────────────────────────┘   │  POST /v1/ui/actions (ada)       │
                                     └───────────────┬──────────────────┘
                                                     │
                                     ┌───────────────▼──────────────────┐
                                     │ agent_flutter + tiko_widgets     │
                                     │  TikoSurfaceView (satu widget)   │
                                     │   ├─ A2uiAdapter (jembatan ke    │
                                     │   │   a2ui_flutter A2uiSurface)  │
                                     │   ├─ TikoCatalog (whitelist)     │
                                     │   └─ fallback GenUiMessageView   │
                                     │ Dipakai: chat, bot manager,      │
                                     │ kanban, automation, teams, MCP,  │
                                     │ approvals                        │
                                     └──────────────────────────────────┘
```

### 5.2 Tiga jalur kehadiran UI

| Jalur | Pemicu | Transport | Klien |
|---|---|---|---|
| J1: inline di chat | tool `render_a2ui` / blok ` ```a2ui ` | balasan teks (fence) + WS `surface` | semua klien Flutter; gateway lain terdegradasi bundel teks |
| J2: halaman GUI | event `surface.created/updated` | WS `/v1/stream` (sudah ada) | panel **Surface** (tab baru) & kartu di halaman terkait (Kanban/Teams/Settings) |
| J3: MCP masuk | hasil tool dari agen eksternal didaur ulang (seperti `@a2ui/catalog-mcp`) | file + session `mcp:*` | chat web + log MCP |

---

## 6. Apa yang DIUBAH

### 6.1 `packages/agent_core` — berkas baru `lib/src/agent_a2ui.dart` (murni Dart, tanpa dependensi baru)

Modul validasi & model pesan A2UI v1.0 milik Tiko sendiri — ini *bukan* import pustaka A2UI, melainkan "aturan masuk Tiko" untuk pesan berformat A2UI:

- `A2uiMessage` (sealed): `CreateSurface(surfaceId, components)`, `UpdateComponents(surfaceId, components)`, `DataModelUpdate(surfaceId, data)`, `DeleteSurface(surfaceId)`.
- `A2uiComponent`: gaya model A2UI — flat, komponen punya `id`, `type`, `componentProperties`, `children` (daftar id).
- `parseA2uiMessages(String raw)` — menerima JSON array atau JSONL; dedupe `componentId`; bila komponen id sama muncul lagi 2× → dilarang (UpdateComponents menimpa tanpa duplikat id); batas-batas (beri nama konstantanya): `a2uiMaxMessages = 24`, `a2uiMaxNodes = 120`, `a2uiMaxDepth = 8`, `a2uiMaxTextChars = 4000`, `a2uiMaxActions = 8`, `a2uiMaxSurfaces = 8` per sesi.
- Katalog terverifikasi Tiko: `tikoAllowedA2uiComponents = {Row, Column, List, Card, Tabs, Modal, Divider, Text, Image, Icon, Button, TextField, CheckBox, ChoicePicker, Slider, DateTimeInput, Metric (katalog kustom), Chart (katalog kustom), KanbanCard (katalog kustom)}`. ID katalog di-whitelist (`tiko.basic.v1`, `tiko.charts.v1`); katalog lain → ditolak (aturan `parsing_a11y.catUnknown`).
- `tikoA2uiSystemPromptAddon()` — teks pengajaran protokol ala `A2uiGenerator` (versi Tiko, ~2.500 char, hanya menyebut tipe whitelist), disuntik bila provider/chat mengaktifkan generative UI (nilai default: aktif di chat, nonaktif di batch/scheduler).
- Re-ekspor bank tool ` ```genui ` lama: `extractGenUiBlocks` tidak disentuh.

Dengan ini, data A2UI mentah tidak pernah bisa masuk tanpa melewati validasi di lapisan paling luar.

### 6.2 `packages/agent_tools` — tool baru `render_a2ui`

Tiru pola `RenderUiTool` (`render_ui_tool.dart`):

- nama: `render_a2ui`; risiko: `medium` (sama dengan render_ui).
- masukan: `{ "messages": [ <A2uiMessage>… ] }` atau `{ "surfaceId": …, "components": [...] }` (mode update permukaan yang sudah ada).
- keluaran: teks ````a2ui\n<len JSON>\n```` + pesan ringkas; kontrak test: echo kecil.
- alias lama `render_ui` **tetap terdaftar** (tidak dihapus).

### 6.3 `packages/tiko_runtime` — berkas baru `lib/src/a2ui_bridge.dart` (part of tiko_runtime.dart)

- `A2uiToolBridge` (kelas kecil dipanggil dari `tiko_runtime.create()` di samping `RenderUiTool`):
  - `handleRenderMessages(raw)` → validasi via `agent_core/agent_a2ui.dart` → teks fence `a2ui` + event `surface.created`/`surface.updated` (EventBus → sudah memantul ke WS `/v1/stream`).
  - `SurfaceStore` kecil: `data/surfaces/<sessionId>/index.json` + `<surfaceId>.json` (atomik, TTL 7 hari, LRU maks 256 surface; scan otomatis aman multi-proses dengan pola `CrossProcessLock` yang sudah ada).
  - Aksi user masuk via binding `POST /v1/ui/actions` yang sudah ada → diperkaya dengan `surfaceId` → jalan `sendUiAction` → event `surface.action` → turn agent kompakt (maks 1 turn; hasil turn menulis ulang surface bila agen minta).
- Registrasi tool: di `create()` setelah konstruksi (pola DeepResearchTool), tidak di dalam kontraktor — menjaga pola testability yang sudah mapan.

### 6.4 `packages/agent_gateway` — frame WS & REST

- WS frame baru (sekadar data dalam frame `event` yang sudah ada, jadi tanpa dirombak):
  - `{'type':'event','event':'surface.created','surfaceId':...,'sessionKey':...}`
  - `{'type':'event','event':'surface.updated', ...}`
- REST (semua fail-closed 501 bila host tak set callback — pola `/v1/teams`):

| Endpoint | Isi |
|---|---|
| `GET /v1/surfaces` | daftar surface aktif (filter `sessionKey`) |
| `GET /v1/surfaces/<id>` | isi lengkap (komponen + data model) |
| `POST /v1/surfaces` (host-only) | buat/perbarui dari kode Tiko lain (mis. runner riset) |
| `DELETE /v1/surfaces/<id>` | hapus + event |
| `POST /v1/ui/actions` (sudah ada) | diperkaya `surfaceId` + `componentId` |

### 6.5 `apps/tiko_widgets` — paket jembatan A2UI (satu-satunya tempat menyentuh `a2ui_flutter`)

Struktur target:

```
apps/tiko_widgets/lib/src/
  a2ui/
    a2ui_adapter.dart       // wrapper tipis di atas MessageProcessor/A2uiSurface
    a2ui_catalog.dart       // TikoCatalog = basicCatalog() − Video − AudioPlayer
                            //   + Metric, Chart, KanbanCard, ApprovalSheet
    tiko_surface_view.dart  // widget publik
```

- `TikoSurfaceView({surfaceId, initialMessages, onAction})`:
  - `state: loading | ready | error | unsupported(katalog)`.
  - `onAction` → dipetakan ke `sendUiAction` (chat) **atau** callback halaman (Kanban/Teams dll).
  - Bila `a2ui_flutter` gagal (versi API berubah, komponen tak dikenal) → **fallback otomatis** ke renderer lama `GenUiMessageView` bila payload bisa dipetakan, else teks error. Fail-closed dua tingkat.
- Katalog kustom Tiko = komponen `ComponentImplementation` bawaan A2UI dengan props dari `CommonSchemasV1`:
  - `Metric` (label, value, delta) — port dari `GenUiView` case `metric`.
  - `Chart` (bar|line, points ≤31) — port chart lama.
  - `KanbanCard` (column, title, state, labels, taskId) — untuk tampilan tugas.
  - `ApprovalSheet` (risk, summary, commands…) — tampilan approval meminta konfirmasi user.

### 6.6 `apps/agent_flutter` — wiring per halaman

| Halaman | Perubahan |
|---|---|
| **Chat** (`main.dart`, `chat_controller.dart`) | pesan asisten: `GenUiMessageView` diganti `TikoSurfaceOrMessageView` — mendeteksi blok `a2ui` (baru) vs `genui` (lama) vs teks murni; streaming: saat fence `a2ui` belum lengkap → tampilkan skeleton kartu; setelah selesai → render. Toolbar aksi surface: tombol kecil “Muat ulang” dan “Salin JSON”. |
| **Bot Manager** (`bot_manager_view.dart`) | tab baru **Kartu dari Bot**: semua surface yang `origin=bot:<id>` terkumpul; klik kartu → detail `TikoSurfaceView`. Bot bisa "menampilkan status sendiri" tanpa mengubah kode halaman. |
| **Kanban / Tasks** (`tasks_view.dart`) | kartu kolom tertentu dirender `KanbanCard` via surface bila tersedia; trik: task riset Fase D yang selesai menyisipkan surface ringkasan (dibuat `ResearchKanbanTracker`, opsional) sehingga kolom selesai bisa diklik → panel laporan. |
| **Automation** (`automation_view.dart`) | agen bisa men-generate **form terjadwal** (cron, tz, pertanyaan) — tombol kirim langsung memanggil `POST`/`PUT` job yang sudah ada (mengembalikan pertanyaan cron yang biasanya harus diinput manual). |
| **Team run** (`runs_page.dart`) | laporan run Fase C dilengkapi surface DAG ringkas (katalog kustom `Chart` + `KanbanCard`) bila generator mengirimnya; fallback markdown seperti sekarang. |
| **MCP / Security** | permintaan approval dirender `ApprovalSheet` (tetap ada tombol approve/deny backend lama). |
| **Panel Surface global** | halaman baru kecil (`surfaces_view.dart`): daftar semua surface aktif + filter sesi; pintu masuk J2. |

### 6.7 `apps/agentd` (+ CLI `tiko`)

- `agentd`: set callback `surfaceStore`/`uiAction` seperti pola `researchRunsProvider` (PR #146).
- CLI:
  - `tiko surface list [--session S]`
  - `tiko surface show <id> [--json]`
  - `tiko surface delete <id>`
  - Dokumentasi `tiko help` + `_usage` diperbarui.

---

## 7. Apa yang TIDAK DIRUBAH (jaminan kompatibilitas)

| Tidak diubah | Alasan |
|---|---|
| Aturan masukan (`GenUiSpec`) grammar `genui` dan renderer lama | backward compat; klien/skrip lama; pola sudah well-tested |
| Tool `render_ui`, nama & kontrak | kompatibilitas; hanya ditambah `render_a2ui` |
| `POST /v1/ui/actions` (path, auth, bentuk) | sudah dipakai Flutter; hanya field opsional ditambah |
| Provider adapters (`agent_providers`) | generative UI terjadi pasca-teks; provider tak tahu A2UI |
| Scheduler/bot/gateway non-HTTP | menerima balasan teks (fence) — 0 perubahan |
| Config `agent.yaml` | tidak ada field wajib baru; opsional `ui.surfaces.enabled: true` |
| Format session/memory/eventstream historis | surface disimpan terpisah (`data/surfaces/`), bukan di session |
| Prefers CI: tanpa `dart format` ke berkas existing, tanpa ketergantungan baru di `agent_core`/`agent_gateway` | menjaga diff CI kecil |
| Dependensi | `a2ui_flutter`/`a2ui_core` hanya di `apps/tiko_widgets` (dan hanya pada Fase E2); `video_player` dihindari (komponen Video/AudioPlayer dikeluarkan dari katalog Tiko) |

---

## 8. Skema pesan & kontrak JSON

### 8.1 Amplop blok fence di teks chat (transport J1)

````
```a2ui
{"messages":[
  {"createSurface":{"surfaceId":"s-chat-1","components":[
     {"id":"root","type":"Column","componentProperties":{},"children":["c1","c2"]},
     {"id":"c1","type":"Text","componentProperties":{"text":"CPU 87%"}},
     {"id":"c2","type":"Button","componentProperties":{"label":"Lihat proses",
        "action":{"name":"inspect_matching","surfaceId":"s-chat-1"}}}
  ]}}
]}
```
(contoh: satu blok fence `a2ui` — tanpa spasi aneh, hanya ilustrasi)
````

Aturan transport:
- Maksimal **4 blok `a2ui` per pesan** (paritas `genui`), masing-masing ≤ 24 KiB.
- Partial saat streaming: bila fence belum ditutup, renderer menampilkan skeleton, parsing baru saat fence tertutup.

### 8.2 Bentuk komponen (disalin dari A2UI v1.0, divalidasi `agent_a2ui.dart`)

```json
{
  "id": "c1",                       // [A-Za-z0-9_.-]{1,64}, unik per surface
  "type": "Button",                 // tipe whitelist Tiko
  "componentProperties": {          // skema per tipe katalog; kunci tak dikenal → ditolak
    "label": "Lihat proses",
    "action": {"name": "inspect_matching", "payload": {"pid": 123}}
  },
  "children": ["c2"]                // opsional; hanya untuk tipe container
}
```

Validasi wajib (mirip `genui.dart`):
- `id` regex `^[A-Za-z0-9_.\-]{1,64}$`; tepat satu `root`.
- Tipe tidak ada di whitelist → pesan ditolak (bukan diabaikan).
- `action.name` regex `^[a-z][a-z0-9_]{1,64}$`; Tiko mengirimnya sebagai `onAction(actionName, payload, surfaceId)` ke runtime → tool call via approvals, **bukan** exec langsung.
- Jumlah pesan/node/kedalaman dan panjang teks dalam batas § 6.1.

### 8.3 Peta korespondensi `genui` → A2UI (untuk migrasi konsumen)

| `genui` | A2UI (katalog Tiko) | Catatan |
|---|---|---|
| `section(title, children[])` | `Card > Column` | judul = header Card |
| `text(text, style)` | `Text` (style `heading/mono/body` → mapping) | |
| `metric(label, value, delta?)` | komponen kustom `Metric` | port 1:1 |
| `chart(kind: bar\|line, points[])` | komponen kustom `Chart` |maks 31 titik |
| `form(fields[])` | `TextField / CheckBox / ChoicePicker / Slider / DateTimeInput` | 1 field = 1 komponen; wrapper `Column` |
| `actions(buttons[])` | `Row > Button[]` | action → `onAction` |
| `divider` | `Divider` | |

### 8.4 Frame event WS (tetap di dalam pola `type:'event'`)

```json
{"type":"event","event":"surface.created","surfaceId":"s-chat-1","sessionKey":"web:abc","origin":"model"}
{"type":"event","event":"surface.updated","surfaceId":"s-chat-1","sessionKey":"web:abc","origin":"model"}
{"type":"event","event":"surface.action","surfaceId":"s-chat-1","action":"inspect_matching","by":"user"}
```

### 8.5 Katalog & negosiasi kapabilitas

- `catalogId` Tiko: `tiko.basic.v1`, `tiko.charts.v1`, `tiko.kanban.v1` — daftar didaftarkan di `tikoAllowedA2uiComponents`.
- Dokumen katalog lengkap dapat ditarik provider/render lewat `GET /v1/surfaces/catalogs` supaya klien tahu bentuk persisnya; secara default system prompt (§ 6.1) sudah memadai.

---

## 9. Desain UI & UX per permukaan

### 9.1 Token & gaya (mengikuti `docs/09-DESAIN-GUI.md` dan tema Simpul)

- Semua surface di atas kartu `surfaceFlat` = latar `surface`, radius `SimpulTheme.radiusLarge`, tanpa bayangan (flat), 1 hairline border `outlineVariant`.
- Tipografi: judul `titleMedium`, body `bodyMedium` (height 1.4), mono `13pt monospace` — konsisten dengan `GenUiView` sekarang.
- Aksi: tombol utama `FilledButton.tonal`, destruktif `FilledButton` dengan `error`; semua aksi muncul wajib ada label teks (tanpa icon-only) untuk aksesibilitas.
- Dark/light otomatis via ColorScheme; surface TIDAK boleh menaruh warna literal di payload (hanya `tone: primary|neutral|error`) supaya theme tetap satu sumber.

### 9.2 States (wajib semua surface)

| State | Tampilan |
|---|---|
| `loading` | skeleton kartu (2 baris + 1 tombol abu) — muncul saat streaming |
| `ready` | konten |
| `error` | kartu merah lembut “surface tidak dapat dirender (<alasan>)” + tombol “Lihat JSON” (fold) |
| `unsupported` | kartu abu “katalog <id> tidak didukung di klien ini” |
| `stale` (>TTL / sesi mati) | bar abu “surface lama” + tombol “Segarkan” |

### 9.3 Interaksi khas chat

- Surface di dalam gelembung asisten: tetap di gelembung; kartu surface memakai lebar maks 760 (sama dengan bubble).
- Setiap surface punya menu ⋮: `Salin JSON`, `Buka panel lebar` (buka di panel artifact kanan yang sudah ada).
- Aksi tombol → toast kecil “terkirim”; jawaban agen menyusul di chat (bukan mengganti kartu diam-diam; kartu baru muncul di bawahnya).

### 9.4 Wireframe panel Surface (halaman J2)

```
┌ Surface ─────────────────────────────────────────────────┐
│ [Filter sesi: semua ▾] [Hanya aktif ☑]                    │
├──────────────────────────────────────────────────────────┤
│ ▢ s-chat-1   web:abc       2 menit lalu   origin: model   │  ← klik → panel detail
│ ▢ s-kanban-3 riset:auto    1 jam lalu    origin: riset    │
├──────────────────────────────────────────────────────────┤
│ (detail)  TikoSurfaceView penuh + riwayat update          │
└──────────────────────────────────────────────────────────┘
```

### 9.5 Wireframe chat (inline surface)

```
│ Bot  ─────────────────────────────────────────────────    │
│ Berikut status sistem dan akses cepat:                    │
│ ┌────────────────────────────────────────────────┐        │
│ │ ●  CPU 87%  ▲ 3%      RAM 62%                  │        │
│ │ [bar chart 12 titik]                           │        │
│ │ [ Lihat proses ]  [ Jalankan diag ]            │        │
│ └────────────────────────────────────────────────┘ ⋮      │
│ Apakah ingin saya periksa lebih dalam?                    │
```

---

## 10. Fitur diferensiasi: yang Tiko punya tapi AI agent lain belum ada

Riset fondasi (Hermes/Claude Code/Codex/Cursor/Gravity) menunjukkan semua punya chat + tool, tetapi kombinasi Tiko + A2UI memungkinkan fitur baru yang belum standar:

1. **Control Surface lintas halaman (J2).** Hermes/ChatGPT membuat UI hanya di dalam chat. Tiko bisa menempatkan surface agen di **halaman GUI non-chat** (bot manager, kanban, automation) — bot membangun "dashboard sendiri" dari data runtime, tanpa developer menulis widget khusus.
2. **Form terjadwal agen-generated.** ChatGPT Tasks mengambil penjadwalan lewat dialog tetap. Tiko bisa meminta agen meng-generate **form cron lengkap** via katalog (`DateTimeInput` + `Slider`) saat user bilang "jadwalkan riset setiap hari kerja jam 7.30" — tombol kirim langsung membuat job (`[RISET] …`), termasuk pratinjau cron di UI.
3. **Approval Sheet visual.** Hermes approval berbasis teks CLI. Tiko merender rencana aksi berisiko (`shell`, `http_request`) sebagai `ApprovalSheet` — daftar command + risiko + tombol Approve/Deny yang terhubung sistem `approvals` (fail-closed) yang sudah ada. UI konsisten di web/desktop/mobile.
4. **Kanban-aware UI.** Task riset otomatis (Fase D) dapat menyarankan surface ringkasan pada kartu selesai — chat dan board sama-sama hidup, bukan hanya board statik.
5. **MCP dua arah.** Tiko adalah MCP server (stdio) **sekaligus** host GUI: hasil tool agen eksternal (Claude Desktop dsb.) yang masuk lewat `mcp:*` bisa dirender sebagai surface di web Tiko — tidak ada AI agent lain yang merender UI untuk agen lain di dalam dirinya.
6. **Fallback gateway universal.** Surface otomatis terdegradasi bundel teks+markdown di Telegram/Discord/SMTP/Matrix (gateway punya `routeForNotifications`/fallback), sedangkan Hermes/compose-type agent tidak punya notifikasi terstruktur ini — Tiko jalan di semua kanal dengan pengalaman terbaik per kanal.

---

## 11. Strategi anti-konflik & adaptasi perubahan API

### 11.1 Anti-corruption layer (ACL)

- Hanya `apps/tiko_widgets/lib/src/a2ui/*` yang `import 'package:a2ui_flutter/...'`. Semua paket lain hanya tahu `TikoSurfaceView` + tipe `agent_core/Tiko` sendiri.
- `a2ui_adapter.dart` mengekspos API internal kecil: `TikoA2uiEngine.process(List<Map>) → TikoSurfaceState`, `streamOf`, `dispatch(actionName, payload)`. Jika `a2ui_flutter` mengganti nama kelas/API (plausible pada pre-1.0), yang diubah = 1 file.

### 11.2 Feature flag & graceful degradation

- `data/config` atau `agent.yaml`: `ui.surfaces.enabled` (default `true` di chat, `false` untuk batch). Bila paket A2UI bermasalah, flag dimatikan → sistem kembali ke `genui`+markdown **tanpa kehilangan fitur lain** (jalur lama tetap berfungsi penuh)..

### 11.3 Pin dependensi & matrix

- `pubspec.yaml`: pin `a2ui_flutter: '>=0.4.0 <0.5.0'` (bukan caret terbuka). `a2ui_core` ikut pin transitif; upgrade uji manual di CI Flutter (sudah ada job build web + desktop Android).
- CI tak menambah job baru — job Flutter lama otomatis menjadi uji build katalog A2UI.

### 11.4 Versioning format

- Blok fence: preamble versi — ```a2ui v1 — parser menolak `v0` dengan pesan jelas (bukan crash). Versi berkembang → `v2` hidup berdampingan; kapabilitas dinegosiasikan per `catalogId` (yang memuat versi).
- Field tool: tambahan field baru bersifat **opsional** (parser menolak kunci tak dikenal — tapi regresi hanya mengubah whitelist, bukan data lama).

### 11.5 Anti-konflik Git/workflow (dari pengalaman Fase A–D)

- Satu PR per fase (E1, E2, …), kecil dan independen; tidak menumpuk di PR fase lain.
- Sub-folder file baru (`agent_a2ui.dart`, `a2ui_bridge.dart`, `a2ui/`) → minim tumpang tindih dengan PR berjalan lain (Fase D mepet file `tiko_runtime.dart` — E1 hanya parsial menambah `part`, satu baris).
- Dokumen desain (file ini) di-merge lebih dulu; implementasi fase berikutnya mengikuti fleksibel sesuai review.

### 11.6 Adaptasi bila API Tiko berubah

- `SurfaceStore` dan event semuanya di belakang interface kecil di `agent_core` (kontrak 5 fungsi), sehingga gateway (WS vs HTTP polling) maupun GUI bisa ditukar tanpa menyentuh runtime.

---

## 12. Keamanan

1. **Agen adalah pihak tidak tepercaya.** Semua payload A2UI wajib melewati validasi whitelist (§ 8.2); komponen katalog tak dikenal → ditolak; batas ukuran/depth selalu aktif.
2. **Tanpa eksekusi kode.** A2UI tidak punya eval; path file (Image) dibatasi: `file://` hanya ke `data/uploads/**` → ditolak selain itu; URL `http(s)` dirender bila endpoint `external_media.enabled` (default `false`).
3. **Aksi = tool call.** `action`:
   - diperlakukan sebagai tool call melalui `approvals`; risiko dihitung tool target.
   - Aksi manajemen surface (salin JSON, muat ulang, hapus milik sendiri) tidak memicu tool.
4. **Tanpa `openUrl` callback di Fase E**(jika kemudian diaktifkan, harus allowlist host) — mengikuti model A2UI.
5. **XSS/markdown injection.** `A2uiMarkdown` dirender oleh widget resminya (bukan innerHTML) sehingga tidak mengeksekusi markup; output hanya teks bergaya; `checks` severity `warning`/`info` dihormati di UI.
6. **Sesi terisolasi.** Surface milik satu `sessionKey`; halaman J2 hanya membaca surface sesi milik user web (cookie sesi dari sistem auth tokenless local yang sudah ada).
7. **Rate limit.** Maks 8 surface aktif/sesi, 24 pesan/turn, 24 KiB/blok, total 96 KiB/turn.

---

## 13. Rencana implementasi bertahap E1–E5

> Setiap fase = satu branch `vibe/a2ui-<slug>-073322` + satu draft PR, bisa di-merge berurutan tanpa konflik besar. Masing-masing harus `dart analyze --fatal-warnings` bersih + test hijau + tidak menyentuh berkas panas milik fase lain lebih dari beberapa baris.

### Fase E1 — Validasi & model pesan di `agent_core` (tanpa dependensi baru)
- Baru `packages/agent_core/lib/src/agent_a2ui.dart` (`A2uiMessage`, `parseA2uiMessages`, whitelist, batas).
- Test `packages/agent_core/test/agent_a2ui_test.dart` (≥12 kasus: JSONL, array, root tunggal, duplikat id, tipe asing, batas depth/node/char, action regex, gateway 24KiB).
- Acceptance: murni Dart, lulus CI (analyze + test, dua seed).

### Fase E2 — Renderer jembatan di `tiko_widgets`
- Tambah dependensi `a2ui_flutter` + `a2ui_core` (pin).
- `a2ui/a2ui_adapter.dart`, `a2ui/a2ui_catalog.dart`, `a2ui/tiko_surface_view.dart` + fallback renderer lama.
- Widget test states; job build Flutter lama di CI otomatis menjadi uji kompilasi. Halaman chat memakai renderer ini bila pesan berisi fence `a2ui`.
- Acceptance: build web + desktop CI hijau; fallback tereksekusi saat katalog tak dikenal.

### Fase E3 — Tool + runtime + gateway
- Tool `render_a2ui` (agent_tools), `A2uiToolBridge` + `SurfaceStore` + registrasi (tiko_runtime), event `surface.*` (sudah memantul via EventBus), REST `/v1/surfaces*` + field `surfaceId` di `/v1/ui/actions` (agent_gateway), wiring `agentd`.
- CLI `tiko surface list|show|delete`.
- Acceptance: smoke e2e — `tiko chat` dengan mock provider + prompt “tampilkan kartu cpu” menghasilkan fence `a2ui` tervalidasi; REST CRUD 200/404/501.

### Fase E4 — Halaman GUI + UX states
- `TikoSurfaceOrMessageView` di chat (dengan skeleton streaming), tab **Kartu dari Bot** di Bot Manager, panel Surface global (`surfaces_view.dart`), approval sheet, form terjadwal Automation.
- Acceptance: flow manual + widget test minimal (states loading/ready/error).

### Fase E5 — Diferensiasi & polish
- Surface dari runner riset Fase D (opsional `researchRunStore → surface ringkasan`), DAG view untuk run team, dokumentasi `docs` → update [00-INDEX.md](00-INDEX.md) + [10-WEB-UI.md](10-WEB-UI.md).
- Opsi ekstra (dialog kecil setelah E5): `openUrl` allowlist; katalog chart lanjutan (VegaChart-style) bila dibutuhkan.

---

## 14. Inventaris uji

| Area | Uji |
|---|---|
| `agent_a2ui.dart` | JSONL/array, root tunggal, duplikat id, tipe whitelist, action regex, batas (24 pesan/120 node/depth 8/24 KiB), fallback parse error |
| `a2ui_bridge.dart` | tool render → event `surface.created/updated`; store atomik + LRU + TTL; aksi map ke `approvals`; failure tak mengunci turn |
| `render_a2ui` tool | valid → fence teks; tak valid → pesan error + `success:false`; alias render_ui tetap jalan |
| Gateway | REST 200/400/404/501; frame event terkirim ke WS; sanitasi `surfaceId` (traversal) |
| `tiko_widgets` | states loading/ready/error/unsupported/stale; fallback katalog; theme sama terang/gelap |
| Flutter integration | chat streaming: skeleton saat fence terbuka; render saat fence tertutup; copy JSON; open artifact panel |
| Non-regresi | Semua test lama (gen_ui, chat, research, teams) tetap hijau; `render_ui` path tak berubah |

---

## 15. Matriks kompatibilitas & fallback

| Klien | Inline chat | Panel Surface | Gateway |
|---|---|---|---|
| agent_flutter web (Chrome) | ✅ A2UI native | ✅ | ✅ |
| agent_flutter desktop | ✅ | ✅ | ✅ |
| agent_flutter Android/mobile | ✅ | ✅ | ✅ |
| Flutter dengan `ui.surfaces.enabled=false` | ✅ `genui`+markdown | ❌ | ✅ |
| Telegram/Discord/Slack/WhatsApp/Email/Matrix/LINE gateway | teks + code fence (degradasi) | ❌ | ✅ tetap kirim teks |
| endpoint OpenAI-compat `/v1/chat/completions` | teks (fence ikut di body) | ❌ | ✅ |
| MCP stdio | teks | ❌ | ✅ |
| curl/skrip lama | 100% bekerja (`genui` tak disentuh) | tidak ada | ✅ |

---

## 16. Lampiran: contoh end-to-end

**Pengguna (web):** "beri dashboard cpu dan disk, lalu tombol untuk jalankan pemeriksaan"

1. Runtime memberi `render_a2ui` + system prompt A2UI kepada model.
2. Model memanggil tool:

```json
{"messages":[{"createSurface":{"surfaceId":"s-chat-7","components":[
  {"id":"root","type":"Column","componentProperties":{},"children":["m1","m2","ch1","a1"]},
  {"id":"m1","type":"Metric","componentProperties":{"label":"CPU","value":"87%","delta":3}},
  {"id":"m2","type":"Metric","componentProperties":{"label":"Disk","value":"62%"}},
  {"id":"ch1","type":"Chart","componentProperties":{"kind":"line",
     "points":[{"label":"10:00","value":64},{"label":"10:05","value":71},{"label":"10:10","value":87}]}},
  {"id":"a1","type":"Button","componentProperties":{"label":"Jalankan pemeriksaan",
     "action":{"name":"run_diagnostics","payload":{"targets":["cpu","disk"]}}}}
]}}]}
```

3. `A2uiToolBridge` memvalidasi → menyimpan surface → memasukkan fence `a2ui` ke balasan → event `surface.created` → WS.
4. Flutter chat: GenUiMessageView → `TikoSurfaceOrMessageView` → `TikoSurfaceView` (skeleton saat streaming, penuh setelah fence).
5. User klik **Jalankan pemeriksaan** → `sendUiAction('run_diagnostics', payload, surfaceId)` → `POST /v1/ui/actions` → runtime membawa ke turn agent sebagai tool call via approvals → balasan chat / pembaruan surface (`updateComponents`) mengganti state tombol menjadi “berjalan…”.
6. Di Telegram (degradasi): pesan berisi teks ringkas + code fence (nilai kebab), tombol tidak ada — aman.

**Perubahan API yang diantisipasi (contoh):** bila `a2ui_flutter` 0.5.0 mengganti `A2uiSurface` → `A2uiView`, cukup ubah `a2ui_adapter.dart` (1 file), tanpa menyentuh agent_core/gateway/runtime.

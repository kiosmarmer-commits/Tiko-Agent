# Agent Manager UI (P2-05) — 2026-11-13

Implementasi P2-05 dari `P2-BACKLOG-2026-11-12.md`: tampilan manajer agent di web UI
existing (`apps/agentd/web`) — papan tugas kanban, event runtime live, dan log audit.

## Ruang lingkup

| Komponen | Isi |
|---|---|
| `GET /v1/tasks` | Daftar tugas kanban (JSON `tasks[]`, format `KanbanTask.toJson`) |
| `GET /v1/logs` | Daftar file `audit-*.jsonl` di `logs_dir` (nama + ukuran, terbaru dulu) |
| `GET /v1/logs/<name>` | Isi log, tail maksimal 64 KB (`truncated: true` bila dipotong) |
| Tab "Tugas" | Papan kanban 4 kolom (backlog/doing/done/failed), feed event live, console log |

## Backend (`packages/agent_gateway/lib/src/http_api.dart`)

- Tiga provider injeksi baru mengikuti pola callback existing: `tasksProvider`,
  `logsProvider`, `logContentProvider` — semua opsional; tanpa provider endpoint
  tetap merespons (list kosong / 404) tanpa crash.
- Validasi fail-closed nama log sebelum provider dipanggil: nama kosong, `/`, `\`,
  atau `..` → HTTP 400; nama tak dikenal → 404. Nama di-decode dengan
  `Uri.decodeComponent` sehingga traversal ter-encode (`..%2F`) tetap tertangkap.
- Semua endpoint tetap di balik auth Bearer (query `?token=` juga didukung, pola lama).

## Wiring (`apps/agentd/bin/agentd.dart`)

- Papan tugas: instance `KanbanBoard` kedua pada `<dataDir>/kanban.json`. Aman
  lintas proses karena setiap mutasi (termasuk `list`) berada di dalam
  `CrossProcessLock` yang sama dengan instance milik `KanbanTool`.
- Log: membaca `rt.audit.directory` (sumber kebenaran `AuditLog`), filter
  `audit-*.jsonl`, urut terbaru. Pembacaan tail via `RandomAccessFile.setPosition`
  + `utf8.decode(allowMalformed: true)` agar file yang terpotong di tengah
  codepoint tidak melempar exception.

## Frontend (`apps/agentd/web`)

- `index.html`: tab "Tugas" baru (`#tab-tasks`) — papan kanban, feed event,
  selector log + `#log-view`.
- `app.js`:
  - `loadTasks()` — render 4 kolom + jumlah kartu; semua konten dirender via
    `textContent` (tidak ada interpolasi HTML, konsisten dengan aturan XSS UI).
  - `watchEvents()` — WebSocket pasif ke `/v1/stream` yang sudah ada: koneksi
    tidak mengirim pesan sehingga server tidak menutupnya, dan semua broadcast
    event runtime diterima. Reconnect otomatis dengan backoff eksponensial
    (1 s → maks 30 s, reset saat sukses). Event `job.*` memicu refresh papan
    (debounce via tab visibility).
  - `loadLogs()`/`loadLogContent()` — selector file + tail 64 KB.
- `app.css`: style papan (grid 4 kolom, responsif 2/1 kolom), feed (maks 50 item),
  dan viewer log.

## Keputusan desain

- **Read-only untuk UI**: mutasi kanban tetap lewat agent (`kanban` tool) atau CLI;
  UI hanya mengamati. Ini menjaga atomicity `claim` dan menghindari permukaan
  serangan tulis baru di HTTP API.
- **WebSocket pasif, bukan endpoint baru**: `/v1/stream` sudah broadcast semua
  event; koneksi yang tidak pernah mengirim teks tidak akan ditutup server
  (penutupan hanya terjadi setelah handler pesan teks selesai). Tidak perlu
  endpoint stream kedua.
- **Tail 64 KB, bukan seluruh file**: log audit harian bisa besar; UI hanya butuh
  aktivitas terkini dan batas menjaga memori browser.

## Tes

- `packages/agent_gateway/test/http_api_tasks_logs_test.dart` (baru, 7):
  tasks list, auth wajib, logs list, konten log, 404, penolakan traversal
  (`..%2F`), penolakan nama berslash.
- `apps/agentd/web/app.test.cjs` (+2, total 5): render papan + log sebagai teks
  (payload berisi `<script>`/`<img onerror>` dipastikan tidak diinterpolasi),
  dan feed event live menerima broadcast serta mengabaikan frame malformed.
- Verifikasi penuh: 13/13 `dart analyze --fatal-warnings` bersih; seluruh suite
  lulus (agent_calc 132, agent_core 153, agent_gateway 76, agent_memory 86,
  agent_providers 44, agent_scheduler 35, agent_security 60, agent_tools 249,
  prediksi 108, tiko_runtime 134, agentd 5, UI Node 5).

## Batasan

- Papan tidak auto-refresh saat tab tidak aktif kecuali event `job.*` masuk;
  tombol "Muat ulang" tersedia untuk refresh manual.
- Viewer log hanya tail 64 KB per file; untuk analisis penuh gunakan akses file
  langsung di perangkat.
- Tidak ada aksi tulis (add/claim/complete) dari UI pada batch ini.

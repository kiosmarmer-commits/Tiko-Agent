# GUI-P1-01/02 — Task Board, Event Feed & Logs Flutter (2026-11-18)

Implementasi item **GUI-P1-01** (Tasks board shared) dan **GUI-P1-02** (event
feed + logs) dari laporan audit GUI eksternal, melanjutkan P0 yang tuntas.

## Latar

Web UI (`agentd/web/app.js`) sudah memiliki task kanban, event feed, dan log
browser; Flutter hanya menampilkan event/approval ringkas di dashboard.
Audit menuntut "task board identical data on all clients" dan mewanti-wanti
jangan menampilkan kontrol scheduler (claim/run/pause) sebelum endpointnya
ada.

## Perubahan

### 1. Data layer typed (GUI-P1-01/02)

- `data/models.dart`: `TaskItem` (id, title, state, claimed_by, result,
  default state `backlog`), `LogFileInfo` (name, bytes), `LogFileContent`
  (name, bytes, truncated, content) — factory toleran terhadap field hilang.
- `agent_api_client.dart`: `listTasks()`, `listLogs()`,
  `fetchLogContent(name)` (nama di-encode; 404 → `ApiError.notFound` typed).
- `data/agent_repository.dart`: `tasks()`, `logs()`, `logContent(name)` typed
  dengan `_guard` (network/timeout).

### 2. Route map diperluas

`AppRoute` bertambah `tasks`, `events`, `logs` (non-primer mobile — tetap
dikelompokkan ke More; bottom bar mobile tetap 4 + More, deviasi dari spec
mobile audit yang menaruh Tasks di bottom bar didokumentasikan di bawah).
Label domain kini: Chat, Dashboard, Approvals, Sessions, Tasks, Memory,
Events, Logs, Settings — identik untuk semua platform.

### 3. Halaman baru

- `ui/page_header.dart`: `PageHeader` publik — dipindah dari `_TopBar`
  privat di main.dart sehingga halaman fitur berkas terpisah bisa pakai
  header yang sama; semua halaman lama kini memakai `PageHeader`.
- `ui/tasks_view.dart`: `TaskBoardPage` — grid kanban 4 kolom
  (`kKanbanStates`: backlog/doing/done/failed, sama dengan `KANBAN_STATES`
  web), 2 kolom pada layar sempit; kartu menampilkan title, id, claimed_by,
  result; **read-only** dengan label "read-only" di header (larangan audit:
  kontrol scheduler butuh endpoint CRUD — belum ada).
- `ui/events_view.dart`: `EventsPage` — runtime events terbaru di atas,
  polling admin tiap 15 detik, event `approval.*` ditandai warna warning.
- `ui/logs_view.dart`: `LogsPage` stateful — daftar file log + filter nama,
  klik memuat isi via `repo.logContent` (debounce tidak perlu, on-demand);
  filter isi log menyaring baris; konten dirender sebagai teks monospace
  selectable (SelectionArea) — tidak pernah diinterpolasi HTML; marker
  `[dipotong]` bila truncated.
- `main.dart`: state `tasks` & `logFiles`; refreshAdmin kini 9 GET paralel
  (ditambah tasks + logs); case route tasks/events/logs; halaman pushable
  dari More (Tasks/Events/Logs/Memory/Graf/Editor/Settings).

### 4. Test

- `test/tasks_events_logs_test.dart` (6 test baru): kolom kanban identik
  web + kartu; default state backlog; EventsPage render & metadata;
  LogsPage memuat isi + filter baris + filter nama; repository typed 404
  notFound untuk log tak dikenal (fake HTTP server).
- `test/app_shell_test.dart`: kriteria route map diperbarui — 5 route
  non-primer (tasks/memory/events/logs/settings) dikelompokkan ke More.

## Yang TIDAK termasuk (jujur)

- **Kontrol task claim/complete/pause**: endpoint scheduler CRUD belum
  tersedia di gateway (audit §3.8 melarang menampilkan kontrol tanpa
  endpoint) — board read-only sampai endpoint ada.
- **Live push events/logs ke Flutter**: belum ada WS global; feed tetap
  polling 15 detik (paritas dengan dashboard yang sudah ada).
- Search log hanya lokal pada konten yang sudah dimuat (daemon tidak punya
  endpoint pencarian log sisi server).

## Verifikasi

- Dart/Flutter tidak tersedia di lingkungan penyusunan — verifikasi penuh
  via CI (analyze/test/build web + desktop + Android).
- Route map & shell yang sama diuji `app_shell_test.dart`.

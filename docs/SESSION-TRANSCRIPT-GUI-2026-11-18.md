# GUI-P0-02: Session Transcript & CRUD — 2026-11-18

## Ringkasan

Implementasi item **GUI-P0-02** (dan sebagian GUI-P0-01 parity) dari audit GUI
`TIKO-AGENT-GUI-REPORT.md`: sesi lama kini bisa dibuka kembali dengan isi
transcript lengkap, bukan sekadar list ID + chat kosong. Ditambah CRUD dasar
sesi (rename, delete) dari GUI Flutter.

## Perubahan

### Backend (`agent_gateway`, `agent_core`, `agent_memory`, `agentd`)

- `GET /v1/sessions/{id}/messages?limit=&offset=` — transcript sesi, oldest
  first. `limit` di-clamp 1..200, `offset` 0..200 (offset melewati N pesan
  terbaru sehingga klien bisa load-earlier). Belum dikonfigurasi → 501;
  session id invalid (kosong/`/`/`\`/`..`) → 400.
- `DELETE /v1/sessions/{id}` — hapus sesi via `SessionStore.delete`.
- `PATCH /v1/sessions/{id}` (body `{"title": ...}`) — ganti judul sesi.
- `SessionStore.rename()` — method baru dengan default `false` (pola sama
  dengan `searchSessions` sehingga tidak merusak implementor lain);
  `FileSessionStore` meng-override dengan redaksi judul + persist atomik.
- `agentd` menyambungkan ketiga callback ke `rt.sessions`.

### Flutter (`apps/agent_flutter`)

- `AgentApiClient.fetchSessionMessages/deleteSession/renameSession`.
- `ChatController.openSession(sessionKey)` — memuat transcript (limit 200 =
  kapasitas penuh store) dan mengganti isi chat; kegagalan tampil sebagai
  pesan system, bukan crash.
- `_SessionsPage`: memilih sesi kini memuat transcript (bukan `clearChat`),
  judul sesi ditampilkan, banner error, dan menu aksi per sesi
  (Ganti nama / Hapus dengan dialog konfirmasi). Menghapus sesi aktif
  mengembalikan chat ke `flutter:default`.

## Yang belum (jujur)

- Belum ada cursor-paging per pesan di store (`recent(limit)` saja) — paging
  dilakukan via offset dari ujung terbaru; kapasitas transcript per sesi
  dibatasi `maxMessagesPerSession` (default 200).
- Belum ada archive/export sesi; belum ada transcript replay di web UI
  `agentd/web`.
- Tidak dieksekusi lokal (sandbox tanpa Dart/Flutter) — verifikasi via CI:
  `dart analyze --fatal-warnings`, `dart test` (agent_gateway, agent_memory),
  `flutter analyze` + `flutter test` (agent_flutter).

## Test

- `packages/agent_gateway/test/http_api_session_messages_test.dart` — 8 test:
  paging + clamp, id invalid, 501 belum terkonfigurasi, delete, rename, 404
  rename unknown, auth.
- `packages/agent_memory/test/file_session_store_test.dart` — 2 test baru:
  rename persist antar-proses, rename gagal (unknown/kosong).
- `apps/agent_flutter/test/session_transcript_test.dart` — 4 test: fetch
  transcript + query param, rename/delete endpoint, `openSession` mengganti
  isi chat, `openSession` error tidak melempar.

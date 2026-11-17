# API Contract & Error Model Typed (GUI-P0-03) — 2026-11-18

Implementasi item **GUI-P0-03** dari laporan audit GUI (`TIKO-AGENT-GUI-REPORT.md`):
"API contract/error model typed — UI saat ini bergantung Map mentah — Semua page
memakai repository/DTO".

## Yang berubah

### 1. Error model typed di gateway (`packages/agent_gateway/lib/src/http_api.dart`)

Semua respons error HTTP kini membawa bentuk baku:

```json
{"ok": false, "code": "not_found", "error": "<pesan>", "retryable": false}
```

- Kode standar: `unauthorized` (401), `forbidden` (403), `not_found` (404),
  `invalid_request` (400), `not_implemented` (501), `conflict` (409),
  `rate_limited` (429), `server` (500, `retryable: true`).
- `invalid_request` dan `not_implemented` adalah perluasan lokal atas daftar kode
  di laporan audit (yang berisi kode sisi klien `network`/`timeout`).
- Kunci `error` dengan pesan yang sama dipertahankan agar klien lama
  (web UI `agentd/web`) tetap kompatibel.

### 2. Lapisan data typed di Flutter (`apps/agent_flutter/lib/data/`)

- `api_error.dart` — `ApiErrorCode` (enum) + `ApiError` (implements Exception):
  mem-parse error model daemon, fallback pemetaan status, plus factory
  `network`/`timeout` untuk kegagalan transport. Menggantikan
  `Exception('...')` mentah di `AgentApiClient._throwIf`.
- `models.dart` — DTO toleran terhadap field hilang: `SessionSummary`
  (dengan `displayTitle`), `SessionMessage`, `ApprovalSummary` (dengan
  `isPending`), `MemoryFact`, `RuntimeEvent`.
- `agent_repository.dart` — interface `AgentRepository` (dapat diganti fake di
  test) + `HttpAgentRepository` di atas `AgentApiClient`; kegagalan transport
  (`TimeoutException`, `http.ClientException`) diterjemahkan menjadi
  `ApiError.timeout`/`ApiError.network`.

### 3. Konsumsi typed di UI

- `ChatController` kini menerima `AgentRepository` (bukan client mentah);
  fallback UI action 501 kini dicek via `e is ApiError && e.statusCode == 501`
  (bukan string matching).
- `main.dart`: state admin bertipe (`List<SessionSummary>`, `List<ApprovalSummary>`,
  `List<RuntimeEvent>`, `List<MemoryFact>`); halaman Dashboard, Approvals,
  Sessions, Memory, dan More membaca DTO, bukan `Map` mentah.

## Batasan yang jujur

- `status`, `capabilities`, dan baris `doctor` sengaja tetap `Map` mentah:
  payload-nya heterogen dan ditampilkan apa adanya di Dashboard; mengetikkan
  semuanya butuh kontrak runtime yang stabil dan bukan bagian minimal item ini.
- Streaming WebSocket tetap mengalirkan frame `Map` mentah ke controller
  (protokol event stream belum punya schema `event_id`/`schema_version` —
  rekomendasi 8.3 laporan untuk tahap berikutnya).
- `request_id` pada error model belum ditambahkan (butuh korelasi log di daemon);
  bentuk `code`/`error`/`retryable` sudah konsisten di semua error path.
- Halaman web `agentd/web` masih membaca kunci `error` lama (tetap kompatibel),
  belum memakai `code`.

## Test

- `packages/agent_gateway/test/http_api_error_model_test.dart` — 6 test:
  401/400/404/500/501 (sessions & ui actions) membawa code + retryable benar.
- `apps/agent_flutter/test/api_error_test.dart` — 6 test parsing `ApiError`.
- `apps/agent_flutter/test/agent_repository_test.dart` — 5 test: DTO mapping
  sessions/messages/approvals/memories/events, error HTTP → `ApiError.notFound`,
  kegagalan transport → `ApiError.network`.
- Test lama disesuaikan konstruksi (`ChatController(HttpAgentRepository(client))`)
  tanpa mengubah ekspektasi perilaku.

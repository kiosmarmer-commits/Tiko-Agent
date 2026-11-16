# MCP HTTP Server-Initiated Requests + SSE Resume (C2) — 16 November 2026

Melanjutkan gap P1 `09-ROADMAP-TASKS.md` (MCP HTTP server-initiated SSE GET
dan MCP HTTP protocol/security hardening): request JSON-RPC ber-ID dari
server kini **dijawab** (opt-in, terbatas) dan GET SSE mendukung **resume
`Last-Event-ID`**.

## Sebelum vs sesudah

| Aspek | Sebelum | Sesudah |
|---|---|---|
| Request server ber-ID di runtime | Hanya dicatat (`serverRequests`) — `EnhancedHttpMcpClient` tidak pernah dipakai di luar test | Opt-in via `mcp.answer_server_requests: true` — `McpToolLoader` memakai `EnhancedHttpMcpClient` + `McpServerRequestHandler` |
| Eksposur tool ke server MCP | — (tidak ada jawaban) | Hanya tool berisiko `low` dari registry runtime; `tools/call` berisiko tinggi tidak mungkin dijawab |
| Batas handler | — | Bawaan handler: concurrency 10, timeout 30 s, sampling rate-limit 10/menit, error terkode (-32601/-32005/-32603) |
| SSE reconnect | Reconnect bounded backoff, event setelah putus hilang | Header `Last-Event-ID` dikirim pada (re)connect dari id event terakhir yang diterima |
| Config | — | `mcp.answer_server_requests` (default `false`, fail-closed; nilai non-boolean → issue + default) |

## Implementasi

- `agent_tools/mcp/http_client.dart`:
  - Parsing baris `id:` pada SSE → `_lastEventId` (getter publik
    `lastEventId` untuk diagnostik/test).
  - `_startEventStream()` mengirim header `Last-Event-ID` bila sudah ada id
    event — sesuai spesifikasi SSE/Streamable HTTP untuk resume.
- `agent_tools/mcp/http_server_handler.dart`:
  - `EnhancedHttpMcpClient` kini meneruskan `super.oauth` (sebelumnya tidak
    bisa dipakai dengan server ber-OAuth).
- `agent_tools/mcp/registry_mcp.dart`:
  - `McpToolLoader(answerServerRequests: false)` — saat aktif, transport
    http memakai `EnhancedHttpMcpClient(toolRegistry: _serverRequestTools())`
    dengan registry terfilter hanya tool `risk == 'low'` (cache sekali).
- `tiko_runtime`:
  - `TikoConfig.mcpAnswerServerRequests` + parsing
    `mcp.answer_server_requests` (validasi boolean, fail-closed) + wiring ke
    `McpToolLoader` di `TikoRuntime.create()`.

## Batasan

- Jawaban `tools/call` dieksekusi langsung oleh `McpServerRequestHandler`
  dengan sesi sintetis `mcp_*` — karena hanya tool `low` yang terekspos,
  tool dengan confirm/permission gate tidak dapat dipicu server. Jangan
  menaikkan flag ini tanpa memahami konsekuensinya.
- Resume bergantung pada dukungan server terhadap `Last-Event-ID`; server
  yang mengabaikannya tetap berfungsi (header diabaikan).
- `resources/read` masih belum diimplementasikan di handler (respons error
  eksplisit), konsisten dengan roadmap resource support.

## Tes

- `packages/agent_tools/test/mcp_http_reconnect_test.dart`: +1 kasus —
  reconnect SSE mengirim `Last-Event-ID: 7` setelah menerima event ber-id.
- `packages/agent_tools/test/mcp_server_request_wiring_test.dart`: +2 kasus —
  flag on: `tools/list` server-initiated dijawab via POST dan hanya tool
  low-risk terekspos; flag off: tidak ada respons (fail-closed).
- `packages/tiko_runtime/test/tiko_config_test.dart`: +1 kasus — default
  false, override true, nilai tidak valid → issue + default.
- Hasil lokal: `dart analyze` bersih; `dart test` — agent_tools 280,
  tiko_runtime 224, semua lulus.

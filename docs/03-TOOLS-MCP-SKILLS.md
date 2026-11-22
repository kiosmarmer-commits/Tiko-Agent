# 03 — Tools, Sandbox, MCP dan Skills

> **Catatan status:** dokumen ini adalah panduan tools, MCP, sandbox, dan skills. Source dan test pada commit `73bbec5` adalah kontrak implementasi; status CI harus dibaca dari GitHub Actions.

**Snapshot:** `73bbec5` (20 November 2026).

## 1. Tool contract dan registry

Semua tool diregistrasi sebagai `ToolSpec` dan dijalankan melalui `RegistryToolExecutor`. Registry memvalidasi object arguments menggunakan subset JSON Schema (tipe, required, minLength, enum dan nested object) sebelum adapter dipanggil. Executor menerapkan timeout per tool dan memotong output di batas `maxOutputChars`.

### Tool inti yang didaftarkan runtime

| Kelompok | Nama/fitur | Keterangan |
|---|---|---|
| Built-in | `datetime`, `calc`, `list_dir`, `grep`, `probe`, `read_file`, `write_file`, `shell`, `web_fetch`, `web_search` | Dibuat oleh `createBuiltinTools`; kalkulator memakai `agent_calc` sandbox |
| Arsip | `unzip_archive` | Ekstrak zip di dalam workspace (Fase A.2); anti path-traversal, batas 500 entry / 16 MiB per-entry / 64 MiB total |
| HTTP | `http_request` | Domain allowlist dan SSRF guard sesuai implementasi adapter |
| Memory | `memory_search`, `memory_add` | Melalui `MemoryStore` runtime |
| File recovery | `patch_file`, `rollback`, `list_checkpoints` | Checkpoint workspace dan rollback |
| Browser | `cdp_browser` | Memerlukan endpoint/browser CDP yang tersedia; tidak otomatis terpasang pada host |
| Scheduler | `schedule_job`, `list_jobs`, `cancel_job` | Menulis/membaca `JobStore` |
| Error/coordination | `error_lookup`, `error_record`, `lease` | Penyimpanan error dan lease |
| Invariant/evidence | `invariant_declare`, `invariant_check`, `claim`, `verify_claims` | Guard/inventory klaim dan bukti runtime |
| Deferred/decision/undo | `defer_question`, `answer_deferred`, `list_deferred`, `record_decision`, `why`, `impact_map`, `record_undoable`, `undo`, `list_undo` | Pelacakan keputusan, pertanyaan, dampak dan aksi undoable |
| Governance | `effect_preview`, `secret_broker` | Preview efek dan broker rahasia; tetap tunduk pada gate |
| Agent | `spawn_subagent`, `tool_forge`, `plan_task` | Subagent runtime, tool forge dan perencanaan; beberapa ditambahkan di bootstrap daemon/runtime |
| Ekstensi | Script tools dan MCP proxy tools | Hanya setelah konfigurasi/host memenuhi persyaratan sandbox dan allowlist |

Status nama tool yang aktif dapat berbeda sesuai host/config: script/MCP yang gagal memenuhi syarat tidak dipasang. MCP proxy memakai nama `mcp_<serverId>_<originalToolName>` sehingga nama server ikut menjadi namespace. `ToolRegistry.registerAll()` melakukan preflight seluruh batch; collision dengan registry atau duplikasi di dalam batch menolak seluruh registrasi tanpa menyisakan sebagian tool.

## 2. Urutan izin dan eksekusi

1. AgentLoop meminta PermissionGate memeriksa setiap tool call.
2. Permintaan yang memerlukan konfirmasi menunggu keputusan manusia dari channel yang memiliki approval UI. Channel tanpa mekanisme approval yang aman ditolak.
3. Bila disetujui, gate memvalidasi ulang capability token; token capability tidak diteruskan ke adapter maupun hasil tool.
4. Semua permission diperiksa berurutan sebelum eksekusi. Hanya panggilan berurutan dengan `ToolSpec.parallelSafe == true` dapat dijalankan bersamaan; tool tanpa opt-in adalah serial dan menjadi barrier.
5. Hasil tool dicatat ke audit dan disanitasi. Output workspace dan eksternal dibungkus sebagai data tidak tepercaya; session taint yang meminta konfirmasi tambahan hanya dipicu sumber eksternal (web, HTTP, browser, MCP, script), bukan setiap pembacaan file lokal.

## 3. Sandbox dan tool eksternal

`SandboxRunner.detect()` dapat menemukan `bubblewrap`, Docker, SSH atau `none`. Shell execution, script tools, MCP child processes dan tool forging memiliki kebijakan sandbox masing-masing. Script tools hanya dimuat bila tersedia sandbox OS yang dapat dipakai. MCP stdio baru dijalankan setelah daemon memiliki instance lock.

`none` bukan isolasi OS. `proot` pada Termux juga bukan batas keamanan kuat. Jangan mengiklankan eksekusi shell/MCP sebagai terisolasi kuat pada host tanpa sandbox OS.

`SsrfGuard` melakukan validasi DNS/IP dan koneksi terjaga untuk memblokir alamat loopback, privat, link-local dan reserved. Proteksi ini harus tetap digunakan oleh semua adapter HTTP yang menerima URL dari model/user.

## 4. MCP configuration

Tiko mendukung server MCP `stdio` dan `http`. Config membatasi maksimal 8 server, ID unik, allowlist nama tool non-kosong (maks 128), risk minimal `medium`, dan SecretRef environment/header. Secret mentah di YAML ditolak.

Contoh bentuk konfigurasi (ganti command/URL, tool dan secret sesuai server yang dipercaya):

```yaml
mcp:
  servers:
    - id: local_docs
      type: stdio
      command: python3
      args: [tools/mock_mcp_server/server.py]
      allow: [search_docs, read_doc]
      risk: medium
      enabled: true
      env:
        API_KEY: env:DOCS_MCP_KEY
    - id: remote_docs
      type: http
      url: https://mcp.example.invalid/mcp
      protocol_version: '2025-11-25'
      max_read_retries: 2
      allow: [search_docs]
      risk: high
      enabled: false
      headers:
        Authorization: env:DOCS_MCP_AUTH
```

Contoh di atas hanya skema ilustratif. Jangan aktifkan server yang belum diverifikasi sumber, hak akses, jaringan dan tool-nya. Endpoint `http` adalah URL jarak jauh yang dideklarasikan administrator; loader sengaja tidak menjalankan `SsrfGuard` pada endpoint ini. Karena itu hanya operator tepercaya yang boleh mengubah config MCP dan URL-nya harus ditinjau agar tidak menunjuk ke localhost/private metadata/internal network yang tidak diizinkan.

### Namespacing dan collision policy

Setiap proxy diberi nama `mcp_<serverId>_<originalToolName>`. Built-in tidak dapat ditimpa oleh MCP karena registry menolak nama yang sudah dipakai. Jika server mengembalikan nama tool duplikat setelah namespacing, atau tool bentrok dengan registry, seluruh server tersebut ditolak dan client ditutup. Batch registrasi bersifat atomic; tidak ada proxy parsial yang tersisa setelah kegagalan. Tidak ada silent overwrite atau kebijakan priority yang menyembunyikan tool lain.

### Stdio

`StdioMcpClient` melakukan negosiasi modern melalui `server/discover` (jalur spec `2026-07-28`) dan fallback ke `initialize` versi `2025-11-25` bila server legacy menolak/timeout. Parser juga menerima framing `Content-Length` untuk kompatibilitas server lama, selain JSONL. Server hanya boleh menerima tool yang ada pada allowlist.

### Streamable HTTP

`HttpMcpClient` menangani initialize/session ID, header `mcp-session-id` dan `mcp-protocol-version`, JSON tunggal/batch, SSE pada respons POST, serta GET SSE opsional untuk notifikasi server-to-client. Runtime config mendukung `protocol_version` per server HTTP (default `2025-11-25`, baseline); negosiasi selaras stdio: client mencoba versi modern `2026-07-28` lebih dulu, lalu jatuh ke baseline bila server menolak (RPC error/HTTP 4xx) atau menurunkan versi lewat hasil initialize; versi hasil negosiasi dipakai pada request berikutnya, GET, dan DELETE. Read-only JSON-RPC methods memiliki retry terbatas (default 2, atur melalui `max_read_retries` bernilai 0–3) untuk network exception atau status HTTP transient (408/425/429/502/503/504); `tools/call` dan notifications tidak diulang. Notifikasi GET tersedia melalui `serverEvents` dan `notifications`; server-initiated JSON-RPC request ber-ID di-dispatch ke `McpServerRequestHandler` (via `EnhancedHttpMcpClient`) dan dijawab dengan POST JSON-RPC kembali ke endpoint: `tools/call`, `tools/list`, `resources/list`, `resources/read`, dan `sampling/createMessage` (callback `onSampling`, rate limit `maxSamplingPerMinute`, default 10/menit; tanpa callback ditolak -32601, melebihi kuota ditolak -32005). Event SSE dibatasi 256 KiB secara default dan daftar diagnostik menyimpan maksimal 100 item terbaru. Stream diputus saat close dan session DELETE dicoba best-effort.

**Belum didukung:** resume/cursor untuk GET SSE; OAuth dynamic client registration. Retry `tools/call` sengaja tidak transparan karena operasi bisa non-idempotent. Auth tetap header SecretRef statis. URL HTTP admin-configured menolak user-info/fragment/control chars, tetapi loader tidak menerapkan `SsrfGuard`; hanya operator tepercaya boleh mengubah URL dan jaringan deployment harus membatasi egress. Jalur aktif adalah `http_client.dart` (`HttpMcpClient`); API standalone legacy `mcp/streamable_http.dart` sudah dihapus karena tidak pernah dipakai `McpToolLoader`.

### Tiko sebagai MCP Server

Kebalikan dari MCP client di atas: Tiko juga bisa **menjadi** server MCP sehingga AI agent lain (Claude Desktop, Hermes, editor dengan klien MCP, dll.) dapat mengendalikan Tiko secara penuh melalui protokol standar. Implementasi: `McpAgent` di `packages/agent_tools/lib/src/mcp/agent_server.dart`, diekspos lewat command CLI `tiko mcp`. Status: **Implemented (stdio saja)**.

- **Transport**: JSON-RPC 2.0 newline-delimited stdio. Log hanya boleh ke stderr — stdout murni framing JSON-RPC. Belum ada Streamable HTTP transport untuk jalur server.
- **Handshake**: `initialize` menjawab `protocolVersion` (echo versi klien bila termasuk yang didukung, else `2024-11-05`), `capabilities: {tools: {listChanged: false}}`, `serverInfo: {name: tiko-agent, version: tikoVersion}`. `notifications/initialized` dan `notifications/cancelled` diabaikan tanpa respons. `ping` menjawab `{}`. Method/JSON tidak valid memakai error JSON-RPC standar (`-32601`/`-32700`).
- **Tools yang diekspos** (masing-masing membungkus runtime Tiko penuh, bukan mode degraded):
  - `tiko_chat {text, session_key?}` — satu turn ReAct agent loop penuh via `rt.chatWithStatus` (sesi `mcp:<session_key>`, channel `mcp`), termasuk semua tool internal, memory, skill, dan gate. Footer status jujur ditambahkan pada jawaban: `[status: ok/error; tool_calls: N; tokens: T; retryable: …]`.
  - `tiko_cancel {session_key?}` — sinyal pembatalan turn kooperatif via `rt.cancelTurn`.
  - `tiko_tools` — daftar tool internal Tiko (nama, deskripsi, level risiko) dari `rt.registry.specs`. Ini daftar kapabilitas agent loop, bukan pintu eksekusi tool tanpa gate.
  - `tiko_sessions` — daftar sesi tersimpan (id, channel, judul, jumlah turn).
  - `tiko_status` — versi runtime dan jumlah tool terdaftar.
- **Approval fail-closed**: `tiko_chat` tidak mengoper `confirm`, jadi tool berisiko masuk antrian approval dan harus disetujui secara eksplisit dengan `tiko approve <id>` di terminal Tiko (atau panel web). Ini konsisten dengan jalur headless HTTP.
- **Contoh konfigurasi klien** (mis. Claude Desktop / Hermes / klien MCP lain):

```json
{
  "mcpServers": {
    "tiko": {
      "command": "tiko",
      "args": ["mcp"]
    }
  }
}
```

- **Batasan jujur**: hanya stdio (t belum ada Streamable HTTP server transport); progres turn tidak di-stream ke klien MCP (satu respons final per `tools/call`); klien MCP lain tidak bisa mengintip frame tool per-tool seperti GUI web; sesi MCP terpisah dari sesi CLI/web (`mcp:` prefix) sehingga memori/riwayat lintas kanalan tidak bercampur.
- **Test**: `packages/agent_tools/test/mcp_agent_server_test.dart` — handshake, tools/list, tools/call (sukses, tool tak dikenal, handler lempar exception), ping, -32601, notification tanpa output, -32700.

## 5. Skills lifecycle

Skill disimpan sebagai `skills/<slug>/SKILL.md`. Runtime memuat skill dari workspace. Status di frontmatter bukan bukti approval: saat load status dinormalisasi kembali menjadi draft; status approved/trial/retired dipulihkan hanya dari ledger jika fingerprint konten masih cocok.

Lifecycle operasional: draft → scan → golden evaluation → trial/approval eksplisit → approved; skill dapat rollback atau retired. `tiko skills evaluate <slug>`, `tiko skills approve <slug>`, dan `tiko skills rollback <slug>` menggunakan `TikoRuntime` dan `SkillApprovalLedger`.

Golden evaluator membuat AgentLoop terpisah, memory in-memory terpisah, registry berisi kandidat yang diuji, dan permission gate fail-closed dengan allowlist tool yang diizinkan tugas/skill. Skill yang diedit setelah approval tidak otomatis tetap approved: fingerprint berubah berarti perlu evaluasi/approval ulang.

`SkillMetricsLedger` menyimpan `uses`, `successes`, positive/negative feedback, dan `lastUsedAt` ke `data/skill_metrics.json`. Status approval tetap menjadi tanggung jawab ledger yang berbeda. Sink metrik bersifat fire-and-forget; crash tepat setelah turn dapat menghilangkan satu event telemetri terakhir.

## 6. Batas klaim

MCP mock fixture/test bukan bukti kompatibilitas semua server vendor. Script/MCP/tool forge harus diuji terhadap sandbox host target. Skill golden tests harus punya fixtures yang nyata dan relevan; evaluasi yang tidak punya isolated evaluator harus gagal tertutup, bukan meluluskan skill berdasarkan teks hasil model saja.

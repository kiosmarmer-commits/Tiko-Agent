# Perbaikan: Hardening Klien MCP Streamable HTTP

- Tanggal: 2026-11-09
- Repo: `kiosmarmer-commits/Tiko-Agent` (branch `main`)
- Bloker: prioritas feat #2 sesi "Lanjutkan semua perbaikan menurut prioritas" (DEC-06)
- Jejak audit: feat `f4d61ce` ("feat(mcp): hardening klien Streamable HTTP — session id, SSE robust, netralisasi envelope"), fix `b7ac9fa` + `6c66a85` (perbaikan pasca-review: `ContentType` non-const pada test SSE; assertion escape envelope satu backslash)

## Masalah

`HttpMcpClient` lama bersifat best-effort dan berbahaya untuk server nyata:

- `start()` memanggil `request()` yang memanggil `start()` lagi (guard `_started` saja) — lifecycle rapuh, tanpa proteksi race start bersamaan, dan kegagalan initialize ditelan `catch (_) {}` sehingga dianggap sukses.
- Header `mcp-session-id` dari server diabaikan: server stateful menolak atau membuat session baru untuk setiap request.
- Respons SSE hanya dibaca baris `data:` pertama — server Streamable HTTP yang sah (balasan + notifikasi dalam beberapa blok event) membuat klien error atau salah pesan.
- `listTools` tidak memvalidasi apa pun; `callTool` tanpa batas ukuran dan envelope tanpa meng-escape delimiter di dalam body (injeksi penutup `</untrusted_data>` bisa memalsukan batas data tidak dipercaya).
- `close()` hanya me-reset flag — session di server dibiarkan menggantung.

## Desain

1. **Lifecycle tanpa rekursi** — `start()` idempoten via `_starting ??= _start()`; `_start()` memakai `_send`/`_sendNotification` langsung (tanpa auto-start). `request()`/`notify()` auto-start bila belum. Kegagalan initialize sekarang ***tidak*** ditelan: exception diteruskan dan `_starting` di-reset supaya bisa dicoba ulang.
2. **Session id** — `_post` menangkap `mcp-session-id` dari header setiap respons dan `_requestHeaders()` selalu mengirimkannya kembali. `sessionId` diekspos sebagai getter.
3. **Parsing respons robust** — JSON tunggal, batch (List), dan SSE (`content-type` mengandung `text/event-stream` atau body diawali `data:`). Blok SSE di-split per event, semua baris `data:` per blok digabung; pesan tanpa `id` masuk daftar publik `notifications`, pesan ber-id dicocokkan dengan `id` request (mismatch → `StateError`).
4. **Validasi tools selaras stdio** — nama regex `^[A-Za-z0-9][A-Za-z0-9_.-]{0,95}$`, maks 128 tool, deskripsi dipotong 2000 karakter, schema harus Map (`Map<String, dynamic>.from`, fallback `{type: object}`); entri rusak → `FormatException` (fail-closed, bukan dipakai sebagian).
5. **Batas keluaran + envelope netral** — content maks 128 item, total teks maks `maxOutputChars` (default 100000) → `FormatException`. `isError` → `MCP error:`. Selain itu body dibungkus `untrusted_data source="mcp-http:<server>"` dengan delimiter dalam di-escape (`</untrusted_data` → `<\/untrusted_data`) dan nama server disanitasi `[^A-Za-z0-9_.-]` → `_`.
6. **Terminasi session** — `close()` menyimpan session id, me-reset state, lalu `DELETE` best-effort (timeout 5 detik, kegagalan diabaikan) agar server Streamable HTTP yang stateful bisa membuang session.

## Matriks test

Test hidup di `packages/agent_tools/test/mcp_http_lifecycle_test.dart` — HTTP server mock di loopback yang mensimulasikan server Streamable HTTP penuh (initialize + session id, balasan SSE berisi notifikasi progress dan payload tools, balasan JSON, endpoint DELETE):

| Test | Yang diverifikasi |
| --- | --- |
| "start menangkap session id dan mengirimkannya di request berikutnya" | `sessionId` = `sess-123`, `serverName` terisi, header `mcp-session-id` terkirim di request berikutnya |
| "tools/list via SSE mengembalikan tool dan menyimpan notifikasi" | parse SSE multi-blok: tool `echo` terbaca + notifikasi `notifications/progress` masuk `notifications` |
| "callTool membungkus keluaran dalam envelope untrusted yang di-escape" | envelope `mcp-http:mock-http`, delimiter dalam di-escape satu backslash, penutup tetap di akhir |
| "close mengirim DELETE dengan header session id" | session dihapus di server dengan header yang benar |

Dua kesalahan ketik pada versi pertama test (konstruktor `ContentType` dibuat const; assertion escape raw-string dua backslash) tertangkap oleh gerbang `dart analyze --fatal-infos` dan diperbaiki dalam `b7ac9fa` + `6c66a85`.

## Keterbatasan

- Stream SSE server-initiated terpisah (kanal GET) tidak diikuti; hanya SSE sebagai respons POST yang didukung.
- Tidak ada retry/backoff untuk request transient; circuit breaker berlaku di level provider LLM, bukan klien MCP.
- DELETE session best-effort: server yang tidak menghormati DELETE tetap meninggalkan session sampai timeout-nya sendiri.
- Header autentikasi statis dari config; OAuth dynamic client registration (spec MCP) belum didukung.

## Status

Selesai; menunggu konfirmasi CI hijau di HEAD setelah commit docs ini.

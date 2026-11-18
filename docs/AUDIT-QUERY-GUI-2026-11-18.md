# GUI-P1-11: Audit query browser — 2026-11-18

Item **GUI-P1-11** (Audit query browser, pelanjutan Security Center yang
sebelumnya hanya menampilkan 15 entri ringkas): halaman admin kini punya
**query browser audit penuh dengan filter** di atas endpoint yang
benar-benar ada (`GET /v1/audit`). Read-only; entri tetap dalam bentuk
teredaksi `SecretRedactor` — tidak ada nilai rahasia yang terlihat dari
GUI.

## 1. Runtime (`packages/tiko_runtime`)

- `TikoRuntime.auditQuery({tool, session, risk, verdict, taint, since,
  until, limit, offset, daysBack})`:
  - Sumber digabung: file JSONL harian (`logs/audit-YYYYMMDD.jsonl`,
    `daysBack` default 7 hari — menjangkau entri **prah restart** daemon)
    + buffer in-memory `audit.recent`; **dedupe** via serialisasi entry
    (entri yang sama di disk dan memori tidak ganda).
  - Filter: `tool` case-insensitive substring; `session` persis;
    `risk`/`verdict` case-insensitive substring; `taint` boolean;
    `since`/`until` rentang ISO; baris korup/parsial dilewati
    best-effort tanpa menggagalkan query.
  - Urut terbaru dulu (string `ts` desc), paginate `limit` (clamp 1..200,
    default 50) + `offset`; return `{entries, total}`.

## 2. Gateway (`packages/agent_gateway`)

- Callback `auditQueryProvider(Map<String, dynamic> filters)` — null →
  `501 not_implemented`.
- Route `GET /v1/audit` (auth bearer; method lain → 404).
- `_parseAuditQuery`: query string → filter typed. `limit` wajib 1..200,
  `offset` ≥ 0, `taint` hanya `true|false`, `since`/`until` harus ISO
  parseable, string maksimal 128/64/32 — semua invalid → `400
  invalid_request` (bukan 500).

## 3. agentd wiring (`apps/agentd/bin/agentd.dart`)

- `auditQueryProvider` langsung menyalurkan filter ternormalisasi ke
  `rt.auditQuery(...)` (map → named params; `since`/`until` DateTime
  sudah di-parse gateway).

## 4. Flutter (`apps/agent_flutter`)

- DTO: `AuditEntry` (ts/session/tool/args/risk/verdict/result/duration/
  error/taint) dan `AuditQueryResult` (entries + total).
- Klien: `queryAudit(Map<String, String>)` (GET `/v1/audit?...`, timeout
  15s); repo `audit({tool, session, risk, verdict, taint, limit,
  offset})`.
- `ui/audit_page.dart` (`AuditPage`, StatefulWidget): bar filter (tool,
  session, dropdown risk/verdict, checkbox taint-only, tombol Cari),
  daftar entri (tool + badge risk/TAINT, meta ts/sesi/duration/error/
  result; border merah untuk deny/taint), header "n entri cocok", dan
  tombol **Muat selanjutnya** saat halaman penuh (pagination offset).
- Route `AppRoute.audit` (rail "Audit", ikon receipt_long, non-primary →
  kelompok More di mobile); query **on-demand** (bukan bagian refreshAdmin
  17 GET) dengan state `auditResult`/`auditFilters`/`auditOffset` di
  main.dart; More page memuat ListTile Audit.

## 5. Web parity (`apps/agentd/web`)

- Tab **Audit**: form filter (input tool/session, select risk/verdict,
  checkbox taint) + tombol Cari/Berikutnya; hasil render aman
  `textContent` (header total, badge deny/taint, meta duration/error).
  Query string dibangun manual + `encodeURIComponent` (tanpa
  `URLSearchParams` agar konsisten dengan harness). Test node harness
  +2 (21 total).

## 6. Dokumentasi & test

- Test: runtime 6 baru (`audit_query_test.dart` — filter, rentang waktu,
  JSONL prah restart + dedupe, pagination), gateway 4 baru
  (`http_api_audit_test.dart`), Flutter 9 baru (5 repository + 4 view),
  web 2 baru.
- Verifikasi: `dart analyze` gateway/tiko_runtime/agentd bersih;
  `dart test` gateway 177, tiko_runtime 263, agentd 7 — semua lulus;
  `flutter analyze` bersih; `flutter test` 214 lulus; `flutter build web
  --release` sukses; `node --test` 21 lulus.

## Yang TIDAK termasuk

- **Read-only** — tidak ada penghapusan/reedaksi entri audit dari GUI.
- Cakupan disk dibatasi **7 hari terakhir** (`daysBack` default, file
  lebih tua tetap ada sampai `rotate()` 30 hari) — permintaan
  rentang-waktu disk penuh menyusul bila perlu.
- **Tidak ada** filter berdasarkan konten `args`/`result` (hanya
  metadata); full-text search berikutnya.
- Pagination sederhana (offset + tombol Muat selanjutnya), belum ada
  jump-to-page atau export CSV.
- Query tidak dialirkan real-time; tetap snapshot on-demand per
  tombol Cari/refresh.

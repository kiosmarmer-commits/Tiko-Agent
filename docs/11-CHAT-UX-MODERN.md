# 11 — Referensi UI/UX Chat Modern & Rancangan Perbaikan Chat UI

> **Status:** dokumen analisis + rancangan (P-Chat UX). Audit dilakukan langsung
> atas kode UI Flutter (`apps/agent_flutter`, `apps/tiko_widgets`) dan backend
> (`packages/agent_gateway`, `packages/tiko_runtime`, `packages/agent_core`),
> disandingkan dengan pola UI AI agent lain pada 2025–2026
> (ChatGPT, Claude, Gemini, Perplexity, Cursor, Replit, Hermes).

## 1. Audit UI Tiko saat ini (temuan berbasis kode)

Teknologi: satu pohon widget Flutter Web (identik dengan client desktop/Android),
template `SimpulTheme` flat/modern. Halaman yang sudah ada: dashboard, chat,
sesi, bot, automation/cron, providers, skills, plugins, security, audit, runs,
logs, memory explorer, artifacts, kanban, settings, command palette, multi-pane.

Temuan gap di **pengalaman chat** (inti produk AI agent lain):

| # | Temuan | Bukti |
|---|--------|-------|
| 1 | **Tidak ada renderer markdown.** Balasan asisten dirender `SelectableText` polos — heading, bullet, tabel, tebal, dan kode inline tampil sebagai teks mentah. | `apps/tiko_widgets/lib/src/gen_ui_view.dart:24` (non-`,genui` → `SelectableText`), `apps/agent_flutter/lib/main.dart:1315` |
| 2 | **Tidak ada blok kode terpisah** — tanpa panel monospace, tanpa syntaks highlight, tanpa tombol copy di kode. | idem |
| 3 | **Tidak ada tombol "Salin" per-pesan/per-blok.** Tidak ada satu pun penggunaan `Clipboard` di repo UI. | `grep -r Clipboard apps/agent_flutter` → 0 util |
| 4 | **Tidak ada lampiran file di composer.** Composer hanya mic + textfield + send. | `apps/agent_flutter/lib/main.dart:1395` (`_Composer`) |
| 5 | **Gap attachment end-to-end:** model `InboundMessage.attachments` + `Attachment{type:image|audio|document, urlOrBytes, mime}` ada di agent_core, tetapi **tidak dikonsumsi** runtime; `POST /v1/messages` dan WS `/v1/stream` tidak menerima field `attachments`. | `packages/agent_core/lib/src/models.dart:27`, `grep attachment packages/tiko_runtime` → 0 wiring |
| 6 | **Tidak ada embedded file view dalam chat.** Artifacts ada sebagai halaman terpisah (`GET /v1/artifacts[/read|/diff]` + `artifact_view.dart`), tapi chat tidak punya side panel/preview file/kartu file dari tool trace. | `apps/agent_flutter/lib/ui/artifact_view.dart` (halaman), tanpa panel chat |
| 7 | **Proses kerja agent tidak terlihat di chat.** WS chat hanya mengemit `typing → text → done`; tool traces (`ChatRunResult.toolCallTraces`) tidak ditampilkan inline selama/after turn. Debug = pindah ke halaman Runs/Logs. | `packages/agent_gateway/lib/src/http_api.dart:1068-1078` |
| 8 | **Streaming UX:** jawaban datar datang sekaligus (frame `text` tunggal) — tidak ada efek pengetikan token-level; user dibiarkan menatap "…" lama pada turn berat. | idem |

Yang sudah baik dan dipertahankan: center column 760px, bubble asimetris,
pemilih model/provider per-sesi (chip header), konfirmasi approval inline,
command palette, multi-pane, tema flat yang konsisten.

## 2. Referensi pola AI agent lain (apa yang dipakai siapa)

Postulat umum tulisan-tulisan teardown UI 2025–2026: *model bukan pembeda utama,
interface di sekelilingnya yang membedakan* (Setproduct, SaaSUI, Designpixil).

| Agent | Pola kunci yang relevan untuk Tiko |
|-------|-------------------------------------|
| **ChatGPT** | Sidebar riwayat thread berjudul auto, grup per recency; konvergensi layout: rail kiri + kolom tengah ~720–768px + panel kanan opsional; mode Auto/Fast/Thinking di UI; attachment seamless (gambar + analisis). |
| **Claude** | **Artifacts**: deliverable panjang (dokumen/kode) dipisah dari chat ke panel kanan — chat tetap kontrol surface; tab *Preview* + *Code*; tombol Copy/Publish di chrome artifact, bukan di chat. Upload batch file (multi-PDF). |
| **Perplexity** | Citation inline + sumber panel; related questions menjaga konteks. Analogi Tiko: referensi `@file:`/source inline pada jawaban. |
| **Cursor / Copilot Workspace** | *Review-before-apply*: diff kode ditampilkan sebagai kartu accept/reject; kalau tidak, kartu file yang berubah. Dekat ke approval flow Tiko yang sudah ada — tinggal ditampilkan sebagai kartu diff dalam chat (`/v1/artifacts/diff` sudah ada). |
| **Replit** | Menampilkan pekerjaan otonom: process running + log dalam konteks task, bukan di halaman terpisah. |
| **v0 / Lovable** | Live preview renderable (HTML/komponen) di panel, iterasi di chat. Bisa dipetakan ke `GenUiView` Tiko yang sudah punya blok ```genui. |
| **Hermes** | Chat + observability dalam satu layar: tool/process status ringkas, verbose detail bisa dibuka; jujur soal status (mock/limited). |

Kesimpulan pola: **chat = thread + stream + composer** (kontrol surface);
**segala output panjang/runnable = panel terpisah**; **proses kerja = strip
status inline yang bisa diperluas**; **copy harus selalu ada**.

## 3. Rancangan perbaikan — 4 fase kecil, masing-masing satuan PR

### Fase C1 — Markdown + copy (murni client, tanpa dependency baru) — **Implemented**
- Renderer markdown minimal **tanpa paket baru**: `tiko_widgets/src/markdown_view.dart`
  (`TikoMarkdownView`, parser `parseMarkdownBlocks`, inline `buildInlineSpans`).
- Subset yang didukung: paragraf, heading `#`–`######`, bullet/numbered,
  `**bold**`, `*italic*`, `inline code`, tabel sederhana, blockquote, dan
  **code fence** → widget `_MdCodeBlock` (panel monospace terpisah, label
  bahasa, scroll horizontal, tombol salin). Sintaks di luar subset dirender
  apa adanya (fail-open) — BUKAN CommonMark penuh (label jujur).
- `GenUiMessageView` kini merender segmen non-genui lewat `TikoMarkdownView`;
  blok ```genui tetap berfungsi seperti sebelumnya.
- Tombol **Salin** per-pesan asisten di chat (`Clipboard.setData`) + SnackBar
  "Pesan tersalin" (`main.dart` `_copyMessage`); tombol salin juga di tiap
  code block ("Kode tersalin").
- Auto-scroll follow versi lama tetap (threshold 120px) — tombol "Ke bawah"
  ekspres tidak dibuat karena follow yang sudah ada memadai (keputusan, bukan
  kelalaian).

### Fase C2 — Attachment file end-to-end — **Implemented**
- **Backend (deviasi jujur dari rancangan awal):** TANPA endpoint upload
  `POST /v1/attachments` — gateway stateless (tidak tahu `dataDir` runtime),
  jadi lampiran dikirim inline base64 per pesan:
  `attachments: [{name, mime, data_base64}…]` pada `POST /v1/messages` DAN
  frame WS `/v1/stream` (`HttpApiServer._parseAttachments`). Tidak ada file
  yang disimpan di gateway; byte hanya hidup di memori selama satu turn.
- **Validasi fail-closed** (error 400, bahasa Indonesia, menyebut batas):
  maksimum 4 lampiran/pesan; nama 1–128 karakter aman `[A-Za-z0-9._() -]`;
  mime allowlist `text/*`, `application/json|x-ndjson|yaml|x-yaml|toml|xml|
  javascript|x-sh`, `image/png|jpeg|gif|webp`; maksimum 2 MiB per file;
  base64 padding kurang dinormalisasi otomatis, karakter/panjang invalid
  ditolak.
- **Model:** field `name` ditambahkan ke `Attachment` (agent_core, opsional —
  backwards compatible); type dipetakan `image` bila image/* selain itu
  `document`.
- **Runtime** (`tiko_runtime/src/attachments.dart` → `expandAttachments`):
  dokumen teks → dekode UTF-8, dibaca jadi konteks inline
  `[lampiran: nama (mime, N byte)] … [/lampiran: nama]`, cap 64 KiB per file
  dan 128 KiB total (potongan ditandai jujur); gambar/biner/audio → metadata
  saja (nama, mime, ukuran, checksum fnv-1a) + penanda bahwa runtime ini
  TIDAK dapat membaca isinya — dukungan vision provider belum ada (lie-free,
  bukan pura-pura menganalisis gambar). Lampiran dikerahkan di
  `chatWithStatus(..., attachments: …)` setelah ekspansi `@`-refs; event
  `attachments.expanded` berisi ringkasan per file.
- **agentd**: `handleMessage` meneruskan `m.attachments` ke `rt.chat`.
- **UI (composer):** tombol attach (`Icons.attach_file`, cap ikut ditampilkan
  di tooltip) + chip pratinjau `InputChip` (nama, tooltip mime, tombol hapus)
  di atas input; pesan user menampilkan ringkasan `📎 nama…`. Picker aktif di
  Web via `dart:html` (`<input type=file>` + FileReader, tanpa paket baru) —
  deviasi kecil dari rancangan: pratinjau thumbnail image TIDAK dibuat (chip
  teks saja) agar murni tanpa dependency; platform non-web langsung gagal
  jujur (dialog native butuh plugin) dan mengarahkan ke referensi `@file:`
  (P3) yang sudah bekerja.
- **Fail-closed:** file tak dikenal/oversize/mime-reject ditolak 400 dengan
  pesan bahasa Indonesia; frame WS invalid menghasilkan frame `error`, bukan
  menjalankan turn separuh (setelah penambahan lampiran gagal, pesan tidak
  pernah sampai agent).

### Fase C3 — Embedded file view (artifacts/pane) + kartu diff — **Implemented**
- **Panel file di dalam chat:** tombol folder di header chat (`btn-chat-files`)
  membuka `ChatArtifactPanel` — di layar lebar (≥1100px) panel kanan 380px
  side-by-side, di layar sempit overlay penuh (menggantikan bottom sheet agar
  sederhana). Panel read-only dari endpoint artifacts yang sudah ada
  (`GET /v1/artifacts` listing + navigasi folder + tombol naik + refresh;
  `GET /v1/artifacts/read|diff` untuk preview).
- **Chip `@file:` di pesan:** referensi `@file:` dalam pesan (user maupun
  assistant) dirender sebagai chip monospace (`chip-file-ref-*`) — tap membuka
  file di panel. Parsing di `collectFileRefs` (chat_artifact_panel.dart):
  unik, maks 6, skip `..` dan backslash (fail-closed), tanda baca di akhir
  dipangkas agar ekstensi tidak terpotong; path tetap divalidasi server.
- **Kartu file/diff dalam chat:** pesan dengan field `files` (JSON daftar
  `{path, changed}`) merender kartu `_FileCard` (ikon file/diff, label
  "berubah", tombol "Lihat" + "Diff") — tap Diff membuka panel dengan tampilan
  diff vs `.bak` langsung (`_openArtifact`).
- **Catatan jujur (batasan C3 saat ini):**
  - Kartu file/diff **sudah dirender** bila `message['files']` ada; sejak C4
    field ini terisi otomatis dari frame `chat.tool` (lihat fase C4).
  - Panel memakai listing global `/v1/artifacts`, bukan per-sesi filter —
    endpoint filter per-sesi belum ada.
  - Tidak ada download/thumbnail; preview hanya teks + diff (file biner
    ditandai tanpa isi, sesuai endpoint).

### Fase C4 — Process running/debugging di dalam chat — **Implemented**
- **WS richer frames (`/v1/stream`):** param baru `onMessageWithProgress` di
  `HttpApiServer` — agentd mengirim frame progress live ke klien WS yang
  meminta: `chat.status` (`running` di awal, `done` di akhir turn),
  `chat.toolStart` (nama tool yang MULAI dieksekusi — tanpa args), dan
  `chat.tool` (tool selesai: nama, `is_error`, `duration_ms` nyata, plus
  `path` bila tool file builtin punya args `path` — args sudah tersanitasi
  sanitizer runtime). Lalu `text`/`done` seperti sebelumnya. Plumbing:
  AgentLoop punya hook `onToolCallStart` + `onToolTrace` yang diteruskan
  `rt.chat(..., onToolStart:, onToolTrace:)` oleh agentd.
- **UI:** selama turn berjalan tampil **status strip** di atas composer
  (spinner + "Menyusun…" / "Menjalankan <tool>…" / "Menghentikan…") dengan
  tombol **Stop** (`btn-chat-stop`); setelah selesai strip menjadi ringkasan
  collapsible (N tool calls, durasi total, jumlah error) dengan detail per
  tool (nama + durasi ms + status).
- **Kartu file/diff otomatis (menuntaskan sisa C3):** frame `chat.tool` dengan
  `path` dikumpulkan ChatController → field `files` pesan assistant
  (`[{path, changed}]`) — kartu C3 kini terisi otomatis dari tool trace;
  `changed` hanya untuk tool tulis (`write_file`, `patch_file`).
- **Cancel:** frame WS `{type: cancel, session_key}` → `cancel_ack` —
  daemon memakai `rt.cancelTurn(sessionKey)` (CancellationRegistry
  agent_core, kooperatif). Klien mengirim via koneksi WS sekali-pakai
  (`cancelTurn`), strip beralih ke "Menghentikan…"; bila teks akhir kosong,
  gelembung menampilkan "(turn dihentikan)" — jujur, tidak mengarang isi.
- **Honest streaming:** tidak ada efek token-level; selama turn tampil
  "Menyusun…" lalu tool aktif; jawaban tetap datang sekali (`text`).
- **Batasan jujur:** HTTP `/v1/messages` tetap sinkron tanpa frame progress
  (jalur WS saja); `chat.tool` tidak menyertakan args sensitif (hanya `path`
  tool file); start tool paralel tidak bergaransi urutan; Stop kooperatif —
  tool panjang harus menghargai cancel token untuk benar-benar berhenti;
  ringkasan tidak menampilkan token (hanya tool + durasi).

## 4. Prinsip yang dipertahankan dari desain sebelumnya (docs/09)
- Flat, modern, simple: token `SimpulTheme`, tanpa shadow berlapis, radius
  konsisten; bahasa Indonesia di seluruh UI; label jujur (mock/limited).
- Layout standar industri: rail kiri collapse di <1200px, kolom tengah ≤768px,
  panel kanan opsional.
- Fail-closed & tanpa kebohongan UX: batas, size cap, dan status selalu
  ditampilkan; tidak ada indikator palsu.

## 5. Urutan eksekusi yang disarankan
1. **C1** (markdown+copy) — paling kecil, dampak UX terbesar, tanpa perubahan API.
2. **C4** (status strip + WS frames) — terlihat segera pada penggunaan harian.
3. **C3** (file/artifact panel + kartu diff) — nilai utama untuk pemakaian coding.
4. **C2** (attachment end-to-end) — paling besar menyentuh backend; terakhir agar
   kontrak API tidak berubah lagi setelah C1/C3/C4 stabil.

Setiap fase: test widget/repo sesuai pola yang ada, update docs/00-INDEX +
docs/10-WEB-UI, label jujur, tanpa dependency baru.

## 6. Fase A — konteks proyek, dokumen, arsip, vision (Implemented)

Ekstensi dari C2 mengikuti cara Claude Code / Codex / Gemini CLI menangani
"/runtime sudah memahami lingkungan + payload user secara menyeluruh":

- **A.1 Project context file** (`context_file.dart`): TIKO.md / AGENTS.md /
  CLAUDE.md / GEMINI.md di root workspace (urutan itu, satu sumber kebenaran)
  disuntik ke system prompt tiap turn tanpa perlu user mereferensikannya.
  Cap 12.000 karakter dengan penanda jujur; fail-closed. CLI: `tiko context`.
- **A.2 Zip auto-extract** (`attachment_ingest.dart`): lampiran zip disimpan
  ke `data/uploads/<sesi-ter-sanitasi>/` lalu diekstrak aman ke folder
  `<nama-tanpa-ekstensi>/` — penolakan entry absolut/`..`, batas 500 entry,
  16 MiB/entry, 64 MiB total ter-ekspansi (zip bomb), listing 30 entry teratas
  inline. Agent menerima path folder hasil ekstraksi untuk dijelajah dengan
  `list_dir`/`grep`/`read_file`. Tool `unzip_archive` (agent_tools) tersedia
  untuk ekstraksi di turn agent biasa dengan jaminan PathSafety yang sama.
- **A.3 Ekstraksi teks dokumen** (`doc_extract.dart`): PDF (header `%PDF`,
  stream FlateDecode di-inflate, operator `Tj`/`TJ`/hex-string), DOCX
  (`word/document.xml`), ODT (`content.xml`), XLSX (`xl/sharedStrings.xml`),
  PPTX (`ppt/slides/slideN.xml`), teks passthrough (mime `text/` atau
  ekstensi teks umum, `.html` dikecualikan). Pure-Dart (`package:archive`),
  fail-closed; file mentah selalu disimpan di uploads sebagai path referensi
  (pola Files API Claude) sehingga turn berikutnya bisa membacanya via tool.
- **A.4 Vision/multimodal** (provider-level): `ChatImage` (base64 + mime) di
  `ChatMessage` — transient per-turn, tidak dipersist ke sesi — dikirim ke
  provider sesuai bentuk API aslinya: openai_compat/azure (`image_url` data
  URL), anthropic (blok `image` base64), gemini (`inline_data`),
  ollama_native (`images[]`), openai_responses (`input_image`). Runtime
  melampirkan maks 4 gambar/turn, 4 MiB/gambar, mime `image/*` saja.
  Catatan jujur: passthrough bergantung gateway mengirim bytes raw (web chat
  mengirim base64 → bytes); provider mock tetap teks.

Batas tetap: lampiran teks 64 KiB/file + 128 KiB total (turun dari kontrak
C2), semua kegagalan per-file menjadi penanda inline jujur dan pesan tetap
terkirim.

## 7. Fase B — loop coding/debugging otomatis `tiko fix` (Implemented)

Paritas loop "edit → jalankan → perbaiki" ala Claude Code / Codex, gate-nya
objektif (bukan klaim model):

- **Gate verifikasi nyata:** tool `verify_project` (agent_tools) menjalankan
  perintah verifikasi (mis. `dart analyze`, `dart test`) dan melaporkan exit
  code + output (tail). `exit 0` = satu-satunya definisi sukses loop.
- **Loop terbatas:** `CodeLoopRunner` — turn 1 menerjemahkan tugas jadi edit
  (tool difilter ke set coding: read/list/grep/write/patch/unzip/verify) →
  verifikasi otomatis → bila gagal, tail output jadi umpan balik prompt
  berikutnya → ulangi sampai lulus atau maks iterasi (clamp 1..8, default 3).
- **Keamanan:** metacharacter shell dilarang (kontrak `shell`); argumen
  path-like divalidasi PathSafety; eksekusi via SandboxRunner bila tersedia,
  fallback argv-exec `Process.run` TANPA shell (cwd dijail workspace) bila
  host tak punya docker/bwrap — dijelaskan jujur di dokumen.
- **Checkpoint & pulih:** snapshot workspace (`.tiko/checkpoints`) dibuat
  sebelum turn pertama; summary hasil selalu menyebut id checkpoint untuk
  rollback via `rollback_checkpoint`.
- **CLI:** `tiko fix "<tugas>" --verify "<perintah>" [--iter 1-8] [--json]`.
  `--verify` wajib — tanpa gate objektif loop menolak jalan (jujur).
- **Observabilitas:** event `code_loop.turn_started` / `code_loop.finished`;
  sesi/channel `fix:*` terpisah dari chat biasa.

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

### Fase C2 — Attachment file end-to-end
- **Backend:** `POST /v1/attachments` (multipart atau JSON base64; batas ukuran
  dan mime whitelist; simpan ke `data/attachments/`, PathSafety) → mengembalikan
  id + nama + ukuran. `POST /v1/messages` dan WS `/v1/stream` menerima
  `attachments: [id… ]` yang diteruskan ke `InboundMessage.attachments`.
- **Runtime:** dokumen teks (txt/md/json/code) → dibaca jadi konteks inline
  `[lampiran: nama.md] … `; gambar → diteruskan ke provider vision bila
  didukung, kalau tidak jawaban jujur dilanjutkan dengan metadata file;
  biner → hanya metadata (nama/ukuran/hash) + penanda.
- **UI:** tombol attach di composer, chip pratinjau di atas input (nama, ukuran,
  tombol remove); pratinjau gambar kecil untuk image; picker lain mengikuti
  platform. Cap jumlah/ukuran lampiran ditampilkan apa adanya.
- **Fail-closed:** file tak dikenal/oversize ditolak dengan pesan bahasa Indonesia
  yang menyebut batas.

### Fase C3 — Embedded file view (artifacts/pane) + kartu diff
- **Panel kanan (desktop ≥1200px):** daftar file workspace/artifacts terkini
  untuk sesi aktif; klik `@file:` di pesan atau path di tool trace membuka file
  di panel (code preview, line number, copy, download).
- **Kartu file/diff dalam chat:** tool trace yang menyentuh file menghasilkan
  kartu ringkas (nama + status) dengan tombol "Lihat" (panel) dan "Diff"
  (`/v1/artifacts/diff`) untuk change yang ada approval-nya — serupa pola
  *review-before-apply* Cursor, diarahkan ke approval flow yang sudah ada.
- Mobile: panel menjadi lembar penuh (bottom sheet), serupa artifact Claude mobile.

### Fase C4 — Process running/debugging di dalam chat
- **WS richer frames:** dari `ChatRunResult.toolCallTraces` + event bus runtime,
  WS mengemit `chat.status` (mulai turn), `chat.tool` (tool mulai/selesai + nama +
  durasi, tanpa argumen sensitif — args sudah disanitasi lewat sanitizer),
  `chat.diff` (opsional), lalu `text`/`done` seperti sekarang. HTTP `/v1/messages`
  tetap sinkron untuk klien sederhana.
- **UI:** selama turn berjalan tampil **status strip** (ikon spinner + nama tool
  terakhir + durasi); setelah selesai strip menjadi ringkasan collapsible
  (n tool calls, durasi, token) yang bisa dibuka → detail trace + link ke Runs.
- **Cancel:** tombol Stop memakai mekanisme cancellation yang sudah ada di
  agent_core; status strip berakhir dengan label jujur ("dibatalkan").
- **Honest streaming:** efek pengetikan menampilkan jawaban yang tersedia
  (satu potong) dengan label "menyusun…", tidak pura-pura token-level.

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

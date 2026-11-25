# 16. Audit Responsive & Accessibility GUI

Status: audit statis kode + komponen yang sudah diterapkan (Hermes S11).
Pengujian visual nyata di perangkat fisik masih perlu verifikasi manual — daftar
periksa tersedia di §2.

## 1. Yang sudah diterapkan

### 1.1 Shortcut keyboard global (Codex item 11)

Widget `GlobalShortcuts` (`apps/agent_flutter/lib/ui/global_shortcuts.dart`)
dipasang sebagai wrapper halaman home; setiap binding diduplikasi `control:`
dan `meta:` agar konsisten di Windows/Linux dan macOS:

| Shortcut | Aksi |
| --- | --- |
| Ctrl/Cmd + K, Ctrl/Cmd + P | Buka command palette |
| Ctrl/Cmd + N | Chat baru |
| Ctrl/Cmd + H | Buka halaman history |
| Ctrl/Cmd + Alt + ↑ / ↓ | Pindah session sebelumnya / berikutnya |
| Ctrl/Cmd + Enter (di composer) | Kirim pesan |
| Esc (global) | Tutup pratinjau artifact, lalu tutup inspector |

Catatan implementasi: `CallbackShortcuts` harus menjadi **induk** dari
`Focus(autofocus: true)` — bila urutannya dibalik, event tidak pernah sampai ke
binding. Esc ditangani global (bukan per-pane) agar aman terhadap dialog: fokus
di dalam dialog berada di luar subtree `GlobalShortcuts` sehingga Esc dialog
tetap bekerja normal.

### 1.2 Error/loading/empty state seragam (Codex item 13)

Komponen bersama `StatusViews`
(`apps/tiko_widgets/lib/src/status_views.dart`) dipakai di seluruh halaman:

- `StatusViews.errorBanner(context, message, {onRetry})` — banner dengan border
  merah, ikon, dan tombol "Coba lagi"; ditandai `Semantics(liveRegion: true)`
  sehingga screen reader membacakan error seketika.
- `StatusViews.loadingBanner(context, {label})` — indikator progres + label
  "Memuat…", juga `liveRegion`.
- `StatusViews.empty(context, message: , detail: , icon: , action: )` — tampilan
  kosong terpusat yang konsisten.

Diadopsi di `main.dart` dan 20+ view (`tasks`, `automation`, `runs`, `skills`,
`security`, `channels`, `events`, `hooks`, `logs`, `audit`, `surfaces`,
`artifact_view`, `chat_artifact_panel`, `plugin/provider/session-history`,
`memory*`, `multi_pane`, `note_chat_panel`). Penggantian bersifat mekanis; teks
pesan dipertahankan sehingga temuan test berbasis finder tetap valid.

### 1.3 Hover/focus/screen-reader aksi

- Seluruh `IconButton` aksi (refresh, close, search, delete) kini memiliki
  `tooltip:` eksplisit (label Bahasa Indonesia) — tooltip sekaligus menjadi
  label aksesibilitas untuk screen reader.
- StatusViews menggunakan token `Theme.of(context).colorScheme` dan `hintColor`,
  bukan warna hard-coded, sehingga mengikuti mode terang/gelap dan high
  contrast bila sistem menyediakannya.
- Struktur breakpoint lebar (`LayoutBuilder`): 900 px (main), 720 px
  (tasks/automation), 1100 px (artifact panel) — teks menggunakan `Expanded`
  dan wrapping, bukan ketinggian tetap, sehingga aman terhadap font scaling.

## 2. Daftar periksa verifikasi manual (perangkat nyata)

Audit visual berikut **belum** dapat dipastikan dari kode dan membutuhkan
perangkat/layar nyata (Codex item 12 sisa):

1. **Layar kecil (Android ≈ 360 dp):** layout mobile satu kolom, composer tetap
   dapat diketik, panel inspektur otomatis menutup.
2. **Tablet / browser sempit:** geser breakpoint 720/900/1100 px; panel artifact
   stack vs side-by-side.
3. **Font scaling** (Android: Settings → Display → Font size maksimal; iOS
   Dynamic Type): pastikan tidak ada teks terpotong banner/command palette.
4. **High contrast** (Windows: High contrast mode; Android: ekstra kontras):
   periksa banner error dan chip filter masih terbaca.
5. **Keyboard navigation murni** (Tab/Shift+Tab/arah): alur command palette →
   pilih session → kirim pesan → tutup panel tanpa mouse.
6. **Screen reader** (TalkBack/NVDA/VoiceOver): liveRegion error, label tooltip
   tombol ikon, dan urutan fokus composer.
7. **Zoom browser 200%** (web build): layout tetap dapat dioperasikan.

## 3. Langkah lanjut yang direkomendasikan

- Tambah `Semantics(header: true)` pada judul halaman bila halaman baru dibuat.
- Uji otomatis aksesibilitas (`semantics` golden test) untuk StatusViews.
- Pertimbangkan toggle ukuran font in-app yang membungkus `MediaQuery
  .textScalerOf`.

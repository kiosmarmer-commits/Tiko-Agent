# 17 — Catatan Audit dan Perbaikan GUI/CLI (26 November 2026)

**Status:** perubahan tercatat pada PR #199, branch `codex/tiko-gui-cli-audit`.
**Snapshot implementasi yang diaudit:** `e5db409` (ditambah `8370064`).
**Sumber perilaku aktif:** source code; dokumen ini tidak menjanjikan parity visual
pixel-perfect antar platform atau hasil verifikasi perangkat nyata.

Dokumen ini mencatat seluruh perubahan GUI dan CLI pada snapshot tersebut serta
menjadi rujukan terbaru untuk area yang ditandai usang di [dokumen desain GUI](09-DESAIN-GUI.md)
dan [audit responsive/accessibility sebelumnya](16-AUDIT-RESPONSIVE-ACCESSIBILITY.md).

## Ringkasan perubahan

### GUI Flutter

| Area | Perubahan | Batas/verifikasi |
|---|---|---|
| Navigasi desktop | Grup **Explore** terbuka otomatis ketika route sekundernya aktif; mode Advanced membuka grup dan menampilkan route aktif. Status terbuka ikut diekspos ke Semantics. | Layout desktop dan mobile tetap memiliki shell responsif berbeda; ini bukan klaim pixel parity. |
| Tema/kontras | `TikoTheme` menyediakan helper bersama untuk menghormati preferensi reduced motion dan memilih foreground aksen yang memenuhi kontras teks WCAG 4.5:1 pada light/dark. Foreground di atas aksen dipilih adaptif; teks nav terpilih, text button, tab, input, dan progress memakai warna yang terbaca. | Rasio dihitung dari warna yang dipakai helper; belum ada pengukuran screenshot lintas semua layar/platform. |
| Pengaturan aksen | Target warna aksen diperbesar menjadi minimum 44×44, diberi label semantik berisi nilai hex, status pilihan, dan tooltip. | Verifikasi perangkat pembaca layar/fisik masih diperlukan. |
| Animasi graph | Perubahan kamera graph tidak menjalankan animasi ketika reduced motion aktif; animasi kamera terdahulu dihentikan sebelum animasi baru dimulai. | Preferensi sistem menjadi sumber reduced-motion untuk helper tema. |
| Status loading/error/empty | `StatusViews` memakai warna dari `ColorScheme`; spinner dan ikon dekoratif tidak menambah noise ke Semantics; error diumumkan sebagai error. | Pengujian pembaca layar pada perangkat belum dilakukan. |
| Pemulihan error | Tombol coba lagi disambungkan ke operasi refresh yang relevan pada halaman yang memakai error state bersama. Panel chat catatan mengulang pertanyaan terakhir; memory explorer/graph memakai pemuatan ulang datanya. | Retry hanya tersedia bila halaman memiliki operasi pemulihan yang sesuai. |

### CLI

| Perintah/opsi | Kontrak setelah perubahan |
|---|---|
| `tiko doctor --json --fix` | Mengeluarkan satu dokumen JSON berisi pemeriksaan dan rencana perbaikan dry-run. Tidak meminta konfirmasi dan tidak menerapkan perubahan. |
| `tiko code-index search --json` | Mengeluarkan tepat satu objek JSON untuk hasil ada, tidak ada, atau indeks kosong; hasil menyertakan snippet bila tersedia dan tidak mencampur teks biasa ke stdout JSON. |
| `tiko config validate --json` | Tetap mengeluarkan JSON ketika validasi menemukan masalah. |
| `tiko session delete ... --json` | Hasil penghapusan menggunakan JSON. Subcommand sesi yang tidak dikenal menampilkan usage dan keluar dengan kode 2. |

Opsi `--json` adalah kontrak untuk stdout yang dapat diparse mesin. Pesan diagnostik
yang memang dialihkan ke stderr tidak boleh dicampurkan ke payload JSON stdout.

## Rincian perubahan source

- `apps/agent_flutter/lib/shell/desktop_shell.dart`: perilaku ekspansi grup navigasi,
  route aktif, serta eksposur expanded state.
- `apps/agent_flutter/lib/ui/theme.dart`: reduced-motion helper dan foreground
  adaptif berbasis kontras untuk tema.
- `apps/agent_flutter/lib/ui/settings_view.dart`: target sentuh dan semantics
  pilihan aksen.
- `apps/agent_flutter/lib/ui/graph_view.dart`: pengendalian animasi kamera saat
  reduced motion dan saat animasi diganti.
- `apps/tiko_widgets/lib/src/status_views.dart`: warna status dari theme,
  semantics untuk error dan ikon/spinner dekoratif.
- `apps/agent_flutter/lib/ui/` (artifact, audit, automation, bot manager,
  channels, events, hooks, logs, memory, mission control, multi-pane, note chat,
  plugin/provider, runs, security, skills, surfaces, tasks): wiring callback retry
  ke state pemuatan masing-masing halaman.
- `apps/tiko/bin/tiko.dart`: JSON konsisten untuk doctor/config/session/code-index,
  perilaku dry-run `doctor --fix`, penanganan subcommand sesi tidak dikenal,
  dan output pencarian indeks untuk hasil kosong maupun berisi.

Commit yang berisi perubahan source: `8370064` dan `e5db409`.

## Dokumentasi atau klaim yang sudah tidak valid

- Snapshot `293c82c` di `09-DESAIN-GUI.md` dan snapshot lama pada
  `16-AUDIT-RESPONSIVE-ACCESSIBILITY.md` **bukan status source terbaru**.
- Pernyataan bahwa seluruh warna teks status mengikuti `hintColor`, bahwa banner
  error selalu merah tetap, atau bahwa semua error state sudah memiliki retry
  generik tidak boleh dijadikan kontrak terkini. Lihat tabel implementasi di atas
  dan `StatusViews` untuk perilaku terbaru.
- Dokumen desain GUI menjelaskan arah dan token, bukan bukti bahwa seluruh layar
  sudah identik antar Android, Web, dan Desktop. Perbedaan shell dan breakpoint
  tetap disengaja.
- Daftar pemeriksaan manual pada dokumen audit lama masih relevan untuk hal yang
  belum diverifikasi secara visual: font scaling, zoom, high contrast, keyboard
  only, screen reader, dan layar fisik. Perbaikan kode tidak menggantikan audit
  runtime tersebut.

## Validasi dan batas bukti

- `flutter analyze --no-pub apps/agent_flutter`: lulus, tidak ada issue.
- `dart analyze apps/tiko`: lulus, tidak ada issue.
- `git diff --check`: lulus pada perubahan source PR.
- Test suite tidak dijalankan secara lokal untuk perubahan ini; gunakan hasil CI
  PR sebagai verifikasi test otomatis terbaru.
- Belum dilakukan screenshot/golden review lintas perangkat atau pengujian
  manual TalkBack, VoiceOver, NVDA, keyboard-only, zoom 200%, dan reduced-motion
  runtime. Karena itu status audit visual/accessibility perangkat adalah
  **belum diverifikasi**.

## Pedoman pemeliharaan berikutnya

1. Saat mengubah route atau mode Simple/Advanced, verifikasi navigasi mobile,
   desktop, dan semantics route aktif.
2. Saat menambah warna aksen, pastikan foreground tetap memakai helper tema dan
   jangan menambahkan warna foreground literal yang melewati pemeriksaan kontras.
3. Setiap error state baru perlu callback retry yang mengulang operasi aman dan
   idempotent; jangan menambahkan tombol retry tanpa handler nyata.
4. Perintah baru dengan `--json` harus mencetak satu dokumen JSON valid pada
   success, empty, dan error yang ditangani, serta memiliki exit code yang sesuai.
5. Perbarui snapshot, tanggal, daftar perubahan, dan status verifikasi pada
   dokumen ini ketika source berubah; pindahkan klaim lama ke label **Historical**
   bila tidak lagi mewakili perilaku aktif.

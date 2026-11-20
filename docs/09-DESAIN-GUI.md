# 09 — Rancangan Desain GUI Tiko Agent (Flat Modern)

> **Catatan status:** dokumen ini adalah rancangan/desain sistem token UI untuk seluruh platform (Android, Web, Desktop). Source (`apps/agent_flutter/lib/ui/theme.dart`) adalah kontrak implementasi token; halaman dapat dianggap terpusat hanya bila warna/spacing/typography diambil dari token, bukan literal.

**Snapshot:** `293c82c` (branch `main`).

## 1. Referensi desain

Rancangan mengikuti pola konsensus antarmuka AI assistant modern (ChatGPT, Claude, Gemini, Perplexity, Le Chat):

| Pola | Praktik fitur lain | Penerapan di Tiko |
|---|---|---|
| Chat full-width, bukan messenger | Bubble hanya pada pesan pengguna; jawaban asisten memakai permukaan datar dengan align kiri | Pesan asisten = panel `surfaceRaised` tanpa border; pesan user = bubble aksen kanan |
| Lebar baca nyaman | ChatGPT/Claude ±768px | `maxWidth: 760` per pesan, konten halaman dibatasi center |
| Composer pil rounded | Input bulat dengan tombol kirim di dalam, bordernya muncul saat fokus | `TextField` tanpa outline di dalam container radius 24 |
| Permukaan flat berlapis lembut | Bukan shadow keras; hierarki lewat 3 warna permukaan | `bg` < `panel` < `surfaceRaised` |
| Seleksi berbentuk pil | Sidebar ChatGPT/Claude menandai item aktif dengan fill rounded | Indicator NavigationRail/NavigationBar memakai `surfaceSelected` |
| Empty state minimal | Logo + satu kalimat ajakan | Ikon brand + "Mulai percakapan dengan Tiko" |
| Status warna semantik | success/info/warn/danger konsisten lintas halaman | Token `success`, `info`, `warn`, `danger` + varian light |

## 2. Token inti

Semua literal warna/spacing/radius/typography di `apps/agent_flutter` wajib berasal dari `SimpulTheme` (`lib/ui/theme.dart`). Token diakses lewat `BuildContext` Extension (`context.simpulPanel`, dst.) agar light/dark otomatis konsisten.

### 2.1 Warna (dark default)

| Token | Dark | Light | Peran |
|---|---|---|---|
| `bg` | `#0F1115` | `#F5F6F8` | Latar kanvas/scaffold |
| `panel` | `#171A21` | `#FFFFFF` | Panel navigasi, header, composer |
| `surfaceRaised` | `#1C2028` | `#FAFBFC` | Kartu, pesan asisten, dropdown |
| `surfaceHover` / `surfaceSelected` | `#232833` / `#2A3140` | `#EDF0F3` / `#DCE7F0` | Hover row & pil seleksi nav |
| `accent` | `#2A9D8F` | sama | Seed warna: tombol primer, link, indikator fokus |
| `userBubble` / `botBubble` | `#1B3A4B` / `#1E2430` | `#D7ECF5` / `#ECEEF1` | Chat |
| `border` | `#2A2F3A` | `#D8DCE2` | Pembatas 1px antar permukaan flat |
| `muted` | `#9AA0A6` | `#5F6672` | Teks sekunder |
| `warn` / `danger` / `success` / `info` | `#E9C46A` / `#E76F51` / `#57B48A` / `#5B9BD5` | varian gelap | Status semantik |

### 2.2 Spacing, radius, typography

- Spacing skala 4pt: `s=4, m=8, l=12, xl=16, xxl=24, xxxl=32`.
- Radius skala flat: `radiusSmall=8` (chip/kecil), `radius=12` (kartu, input, tombol), `radiusLarge=16` (dialog, kartu besar, pil composer=24 via `radiusPill`).
- Typography: satu keluarga font sistem, hierarki `display 28/w600`, `pageTitle 22/w600`, `sectionTitle 16/w600`, `body 14`, `caption 12`. Warna teks mewarisi ambient `DefaultTextStyle` agar theme light/dark tetap benar.

## 3. Pemetaan token ke komponen

| Komponen | Sumber | Aturan flat |
|---|---|---|
| `ThemeData` | `SimpulTheme.theme(brightness, accent)` | Material 3, `splashFactory` non-riak besar, elevation 0 di semua komponen, pembatas 1px |
| Desktop shell | `lib/shell/desktop_shell.dart` | Rail transparan di atas `bg`, pil seleksi `surfaceSelected`, header brand "Tiko" di atas rail, pembatas 1px |
| Mobile shell | `lib/shell/mobile_shell.dart` | NavigationBar depil `surfaceSelected`, elevation 0 |
| Header halaman | `lib/ui/page_header.dart` | Panel flat + 1px border bawah, dot status runtime, trailing opsional |
| Kartu / dashboard | `_Card` (main.dart) dst. | `surfaceRaised`, radius 16, border 1px, judul `sectionTitle` |
| Form/input | tema global | `filled` dengan `surfaceHover`-lite, radius 12, fokus border aksen 1.5px, tanpa shadow |
| Dialog/snackbar/tooltip | tema global | Radius 12–16, floating snackbar, tanpa elevation |
| Chat | `_ChatPage` (main.dart) | Asisten full-width max 760 di `surfaceRaised`; user bubble aksen kanan; aksi suara sebagai caption button |
| Composer | `_Composer` (main.dart) | Pil radius 24 di `panel`, field borderless, tombol kirim `IconButton.filled` aksen |

## 4. Platform paritas

- Satu pohon widget dipakai semua platform; hanya shell yang berganti: NavigationRail (lebar ≥900px) vs NavigationBar (sempit). Karena semua warna berasal dari `Brightness`, Android/Web/Desktop otomatis konsisten.
- Mode Simple/Advanced tetap memfilter route (`GUI-P2-01`); desain tidak menambah/mengurangi destinasi.
- Badge approval pending (`GUI-P0-06`) tetap pada destinasi Approvals di kedua shell.
- Konsolidasi web (Jalur A): `HttpApiServer` melayani hasil `flutter build web` sebagai `webRoot`, sehingga semua permukaan web memakai token yang sama. Dashboard vanilla `apps/agentd/web` (beserta retokenisasi CSS variables-nya) telah dipensiunkan pada fase 3; satu-satunya UI web adalah Flutter Web. Fase 2 menyeragamkan sesi web: index UI yang dilayani agentd menerbitkan cookie sesi same-origin (`tiko_web_session`, HttpOnly + SameSite=Strict) sehingga kolom token di Settings/Bantuan opsional, dan daemon bind loopback otomatis membuka browser ke UI (`TIKO_NO_BROWSER=1` untuk spawn programatik/manual). Rincian penyajian dan keamanan di [10-WEB-UI.md](10-WEB-UI.md).

## 5. Aturan perubahan

1. Dilarang menaruh literal `Color(0x...)` baru di luar `SimpulTheme`; pakai token atau `Theme.of(context).colorScheme`.
2. Elevation/shadow dilarang kecuali scrim modal; hierarki memakai lapisan warna permukaan.
3. Perubahan token harus dicek lintas light/dark dan lebar sempit/lebar (`flutter test test/widget_test.dart test/app_shell_test.dart`).
4. Status penerapan GUI dilaporkan dengan label `Implemented`/`Partial` mengikuti kontrak dokumentasi `00-INDEX.md`.

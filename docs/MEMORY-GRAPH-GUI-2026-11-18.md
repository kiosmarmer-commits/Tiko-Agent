# Memory Graph / Learning Timeline GUI (GUI-P2-05) — 18 November 2026

Status: **Implemented** — timeline kronologis entri memori berlapis dengan
provenance lengkap di dua klien (Flutter + web), tanpa API baru.

Sumber rancangan: `TIKO-AGENT-GUI-REPORT.md` backlog P2 —
`GUI-P2-05 Memory graph / learning timeline … acceptance: visualisasi proses
agent belajar / mengingat dari waktu ke waktu`.

## Keputusan desain

- Tidak ada endpoint baru: `GET /v1/memory/layers` sudah membawa provenance
  per entri (`created_at`, `last_accessed_at`, `access_count`,
  `source_session`, `tags`, `importance`, `layer`) dan `DELETE
  /v1/memory/layers/:id` sudah tersedia.
- Bentuk visual adalah **timeline list kronologis** (dikelompokkan per tanggal,
  diurutkan terbaru), bukan graf geometris node-edge; batasan ini disebut
  jujur di PR.
- Aksi yang tersedia: hapus entri (dengan konfirmasi). API layer belum
  mendukung edit in-place, jadi tidak ada aksi edit.

## Flutter (`apps/agent_flutter`)

- Widget baru `MemoryGraphTimeline` (`lib/ui/memory_graph_view.dart`):
  - grouping per tanggal (10 karakter pertama `createdAt`), grup diurut
    terbaru, header `YYYY-MM-DD · N entri`.
  - badge layer berwarna (`episodic` info, `procedural` warn, lainnya
    success), teks entri 2 baris, chips `#tag`.
  - baris provenance: `akses N · sesi X · terakhir Y` +
    `LinearProgressIndicator` importance berlabel.
  - `IconButton` delete per entri (key `btn-delete-graph-<id>`) dan
    placeholder kosong bila belum ada entri berlapis.
  - label status: `Timeline N entri (terpotong dari T) · diurutkan terbaru`.
- `MemoryExplorerPage`: tab ke-5 **Timeline** pada TabBar/TabBarView
  (`DefaultTabController` length 4 → 5); delete dialihkan ke handler
  `_deleteLayer` yang sudah ada (konfirmasi + toast).

## Web (`apps/agentd/web`)

- Card "Graf / Timeline (GUI-P2-05)" di tab Memori (`index.html`): tombol
  `#btn-load-mem-graph` + daftar `#mem-graph-list`.
- `app.js`: `loadMemGraph()` mem-urlencoded-fetch
  `/v1/memory/layers?limit=200`, sort desc per `created_at`, kelompokkan per
  tanggal, render item `[LAYER] teks` + meta provenance + tombol Hapus; label
  "Hasil terpotong." bila `truncated`. Delegasi klik pada `#mem-graph-list`
  memanggil `deleteLayer(id).then(loadMemGraph)`. Semua render via
  `textContent` (anti-XSS).

## Verifikasi

- `flutter analyze` bersih; `flutter test` 257 lulus (+3 widget test di
  `test/memory_graph_view_test.dart`: grouping/provenance/truncated,
  placeholder kosong, tap delete memanggil `onDelete`).
- `node --check apps/agentd/web/app.js`; `node --test` 37 lulus (+2: render
  grup tanggal + item provenance, delegasi delete memanggil DELETE).
- `bash scripts/web_ui_validate.sh` lulus; `flutter build web --release` sukses.

## Batasan jujur

- Timeline berupa list kronologis, bukan graf geometris (node-edge).
- Hanya aksi hapus; edit in-place belum didukung API layer.
- Timeline dimuat on-demand (tombol), bukan otomatis setiap buka tab.

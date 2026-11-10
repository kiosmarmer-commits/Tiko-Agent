# Arsip: Tiko-Agent UI Repair Overlay

> **Catatan historis.** Dokumen ini berasal dari pengerjaan overlay UI terhadap baseline repository yang lebih lama (commit `787ef904b87c3908f2761fa33747fdead04020c0`). Dokumen ini bukan audit terkini dan bukan petunjuk instalasi untuk branch `main` saat ini.

UI Web yang dibahas pada laporan lama telah menjadi bagian dari source repository: `apps/agentd/web/index.html`, `app.css`, dan `app.js`. Implementasi saat ini menggunakan WebSocket `/v1/stream`, shared approvals endpoint, serta pembentukan elemen DOM dengan `textContent` untuk data eksternal. Validasi UI saat ini tersedia melalui `scripts/web_ui_validate.sh`.

Gunakan dokumen berikut untuk snapshot terkini:

- [`docs/STATUS-2026-11-09.md`](docs/STATUS-2026-11-09.md)
- [`docs/REPOSITORY-AUDIT-2026-11-09.md`](docs/REPOSITORY-AUDIT-2026-11-09.md)
- [`apps/agentd/web/README-UI-REPAIR.md`](apps/agentd/web/README-UI-REPAIR.md)

Catatan hasil uji overlay, patch manual dan keterbatasan saat itu tetap menjadi arsip konteks; jangan menggunakan hash baseline lama sebagai versi source saat ini.

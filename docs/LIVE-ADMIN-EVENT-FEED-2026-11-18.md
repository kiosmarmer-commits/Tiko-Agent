# GUI-P2-06: Live push WS admin feed Flutter — 2026-11-18

Item **GUI-P2-06** (live push WS global admin feed) dari backlog audit GUI:
dashboard admin Flutter kini **menerima event runtime lewat push WebSocket**
dan melakukan refresh segera (debounce 1 detik), bukan menunggu polling 15
detik. Polling 15 dtk **tetap dipertahankan sebagai fallback** untuk kondisi
WS mati/tidak tersedia.

## 1. Client (`agent_api_client.dart`)

- `streamEvents()` — koneksi WebSocket `/v1/stream` dengan one-time ticket
  (pola yang sama dengan `streamChat`; token Bearer tidak pernah lewat URL).
- Hanya frame `{'type': 'event', 'event': {...}}` yang di-yield — frame
  chat (`typing`/`text`/`done`) dan `confirm` diabaikan agar feed admin
  tidak tercemar percakapan; frame non-JSON/bukan-map dilewati.
- Tidak ada pesan yang dikirim lewat socket ini, sehingga server tidak
  menutup koneksi setelah satu turn (perilaku `/v1/stream` gateway:
  menutup koneksi hanya setelah menanggapi pesan `text`).
- Koneksi putus mengalirkan `onDone`/`onError` — reconnection tanggung
  jawab pemanggil.

## 2. Gate reconnect (`data/admin_event_feed.dart`, baru)

- `AdminEventFeed(events, onRefresh)`:
  - **Debounce 1 detik** — burst event (job.* beruntun) dikoaleskan
    menjadi satu refresh; guard `adminRefreshInFlight` yang sudah ada
    mencegah overlap.
  - **Reconnect backoff** — koneksi rusak/putus dijadwalkan ulang dengan
    delay berlipat (2s → 4s → 8s → … dibatasi 60s); delay kembali ke nol
    begitu event kembali mengalir.

## 3. Wiring (`main.dart`)

- Feed **dimulai setelah refresh admin pertama sukses** (daemon benar-benar
  terhubung) — tidak ada koneksi WS yang digantung saat daemon offline;
  polling tetap jalan.
- `updateConnection` (token/base URL berubah): feed lama di-dispose dan
  dimulai ulang dengan kredensial baru lewat refresh penuh.
- `dispose` state: feed di-dispose bersama timer lain.

## 4. Test (5 baru, 181 total)

- `test/ws_events_test.dart` (2, test HTTP/WS nyata loopback — pola
  `ws_stream_edge_test.dart`):
  - `streamEvents` hanya mengalirkan payload event (frame `typing`,
    non-JSON, event bukan-map diabaikan) dan memakai ticket POST
    `/v1/auth/ticket` di query WS.
  - Ticket gagal (401): tetap connect tanpa query ticket.
- `test/admin_event_feed_test.dart` (3, `fake_async`):
  - Burst event dikoaleskan menjadi satu refresh.
  - Koneksi putus → reconnect backoff berlipat (2s → 4s → 8s …).
  - Gagal berulang dibatasi `maxDelay` 60s.
- Repo: `runtimeEvents()` hanya delegasi satu-baris ke
  `streamEvents()` (di-test level client di atas); koneksi WS nyata
  memakai server loopback, bukan mock HttpClient.
- Gateway tidak berubah — memakai broadcast `/v1/stream` yang sudah ada.

## Yang TIDAK termasuk (jujur)

- **Feed event baru di UI**: event masih tampil di halaman Events yang
  ada (refresh kini bisa dipicu push, bukan hanya polling) — tidak ada UI
  baru; data model `RuntimeEvent` tidak berubah.
- **Diff/state persisten antar reconnect**: saat WS putus, event yang
  hilang dipulihkan oleh polling 15 dtk berikutnya, bukan replay.
- **Filter event per-halaman**: debounce berlaku global (satu refresh);
  belum ada mapping event → subset GET tertentu.
- Web UI (`apps/agentd/web`) sudah punya `watchEvents`-nya sendiri dan
  tidak disentuh di milestone ini.

## Verifikasi

- `apps/agent_flutter`: `flutter analyze` no issues; `flutter test` 181
  lulus (6 baru); `flutter build web --release` sukses.
- Batas: hanya frame `event` dari WS `/v1/stream` yang benar-benar
  dibroadcast gateway; tidak ada asumsi endpoint lain.

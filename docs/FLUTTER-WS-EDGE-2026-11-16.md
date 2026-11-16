# Flutter WebSocket Stream — Edge Case Test + Perbaikan Teardown (C5)

Tanggal: 2026-11-16
Status: Row roadmap P1 "Flutter WebSocket URL/token handling". Implementasi dasar (URI transform http→ws/wss→wss, stream ticket satu-pakai sehingga token tidak pernah masuk URL query, `Uri.encodeComponent` untuk ID, sink ditutup saat cancel) sudah ada di `main`. Sisa kriteria: **uji karakter khusus, reconnect, timeout**. Perangkat nyata tetap terbuka (butuh device).

## Bug nyata yang ditemukan dan diperbaiki

**Teardown `streamChat` bisa menggantung** (`apps/agent_flutter/lib/agent_api_client.dart`): bila upgrade WebSocket gagal (server jawab 404) atau koneksi menggantung tanpa respons, `await channel.ready` melempar error — tetapi `finally` lama menjalankan `await channel.sink.close()` yang menunggu close frame **yang tidak pernah datang**, sehingga error asli tidak pernah sampai ke pemanggil dan stream menggantung selamanya.

Perbaikan: teardown kini bounded — `sink.close()` diberi timeout 5 detik, kegagalan diabaikan (best-effort), error asli tetap diangkat ke pemanggil. Terkunci oleh 2 test baru (upgrade ditolak; koneksi tak pernah selesai upgrade → `TimeoutException` dari ready 10 detik).

## Test baru (`apps/agent_flutter/test/ws_stream_edge_test.dart`, 6 test)

Server palsu: `HttpServer` + `WebSocketTransformer.upgrade` di `/v1/stream`, endpoint ticket `/v1/auth/ticket` yang bisa dikonfigurasi statusnya.

1. **Karakter khusus round-trip**: teks dengan emoji, newline, tab, kutip ganda, backslash, karakter éè€ dan sessionKey khusus — sampai server dan kembali ke client persis sama (via JSON encoding).
2. **Frame biner** (bukan string) → dilaporkan sebagai event `{'type':'error','message':'bad frame'}`, bukan crash.
3. **Ticket endpoint gagal (401)** → fallback connect **tanpa** parameter ticket di query; token utama tidak pernah muncul di URL.
4. **Server menutup koneksi mendadak** → stream selesai tanpa menggantung.
5. **Upgrade ditolak (404)** → error terangkat ke pemanggil (sebelumnya menggantung — bug di atas).
6. **Koneksi tak pernah selesai upgrade** → `TimeoutException` dari `channel.ready` setelah 10 detik (teardown tetap selesai).

## Semantik reconnect (dokumentasi jujur)

`streamChat` **sengaja tidak auto-reconnect**: satu panggilan = satu stream, dan `ChatController` menampilkan error agar pengguna bisa retry eksplisit (lihat komentar `chat_controller.dart` "The user can explicitly retry"). Auto-reconnect berisiko mengirim ulang pesan yang sebenarnya sudah diproses server; perilaku retry-eksplisit dipertahankan dan kini terkunci test bahwa kegagalan koneksi selalu terangkat sebagai error, bukan diam.

## Verifikasi lokal (Flutter 3.47.5 / Dart 3.13.4, sama dengan CI)

- `flutter analyze` (apps/agent_flutter): **No issues found**.
- `flutter test` (apps/agent_flutter): **65 lulus** (58 lama + 6 baru + penghitungan suite).

## Batasan yang tetap berlaku

- Pengujian perangkat nyata (Android/iOS lifecycle, backgrounding) tetap terbuka — butuh device.
- Timeout `ready` (10 s) dan `stream` (180 s) hardcoded; belum dikonfigurasi via config (bisa jadi item lanjutan bila dibutuhkan).

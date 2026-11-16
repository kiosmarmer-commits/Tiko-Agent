# Inbound Email — Anti-Replay, Allowlist Fail-Closed, Lifecycle Test (C4)

Tanggal: 2026-11-16
Status: Row roadmap P1 "Inbound email gateway". Receiver IMAP (`ImapPoller`, `packages/agent_gateway/lib/src/imap_client.dart`) dan wiring agentd (env `IMAP_HOST/PORT/USER/PASSWORD/ALLOW/POLL_SEC` → `EmailGateway.pushInbound`) sudah ada di `main`. Sisa kriteria roadmap yang belum terpenuhi: **anti-replay**, **allowlist fail-closed**, dan **lifecycle/shutdown test**. PR ini menutup ketiganya.

## Perubahan

### 1. Anti-replay dedup `Message-ID`
- `ImapEmail` kini membawa `messageId` (header `Message-ID`, kosong bila tidak ada).
- `ImapPoller` menyimpan cache ID terpakai (bounded FIFO, default 512 entri, `replayCacheSize`). Pesan dengan `Message-ID` yang sudah pernah diemisi **dilewati** walau server menyajikannya kembali sebagai UNSEEN (skenario: perubahan UIDVALIDITY, klien lain membuka flag `\Seen`, replay). Pesan tanpa `Message-ID` tidak dapat didedup (tetap mengandalkan `\Seen`).

### 2. Allowlist pengirim fail-closed
- Sebelumnya `allowSenders.isEmpty || contains(...)` — allowlist kosong berarti **izinkan semua**, kontradiksi dengan docstring "allowlist wajib" dan pola fail-closed proyek.
- Kini allowlist kosong berarti **tidak ada pengirim yang diizinkan**. Wiring agentd sudah mewajibkan `IMAP_ALLOW` non-empty (fail-closed di level env), sehingga tidak ada perilaku produksi yang berubah — hanya lubang pada level library yang ditutup.
- Pesan pengirim tidak diizinkan tetap ditandai `\Seen` agar tidak diproses ulang (perilaku lama dipertahankan, kini terkunci test).

### 3. Test baru (dari 6 → 11 test)
- `Message-ID` header diparse ke `ImapEmail.messageId`.
- Allowlist kosong fail-closed: tidak ada yang diemisi, pesan tetap `\Seen`.
- Anti-replay: dua poll berbeda menyajikan `Message-ID` yang sama sebagai UNSEEN → hanya satu emis; poll kedua mengembalikan 0.
- Lifecycle: poll pertama gagal (LOGIN NO) → dilaporkan via `onError`, **loop tidak mati**, poll kedua sukses mengemis; `stop()` menyelesaikan `done` dan idempotent.

## Verifikasi lokal (Dart 3.13.4, sama dengan CI)

- `dart analyze --fatal-warnings`: bersih untuk `agent_gateway` dan `agentd`.
- `dart test`: agent_gateway **100 lulus**, agentd **7 lulus**.

## Batasan yang tetap berlaku

- Tidak ada IDLE IMAP dan tidak ada koneksi persisten — polling berkala dengan koneksi TLS baru per poll (by design, minimal).
- Dedup anti-replay in-memory: cache hilang saat restart proses; setelah restart, pesan yang masih UNSEEN di server akan diemisi ulang satu kali (server-side `\Seen` adalah lapisan utama).
- Live relay/certificate test terhadap server IMAP nyata tetap terbuka (butuh kredensial; bukan bagian CI).

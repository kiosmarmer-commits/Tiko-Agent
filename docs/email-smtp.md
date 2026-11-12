# Email Gateway — Status Implementasi

**Dasar source:** baseline GitHub `main` `dfa7a0ecbd830fd9ecaa50f37145bb27351f5711`; delta timeout SMTP dan regression tests terbaru ada di `docs/STATUS-2026-11-10.md` (belum dipush/divalidasi Dart).

`EmailGateway` saat ini menyediakan **pengiriman outbound SMTP**. Class mempunyai `pushInbound()` sebagai adapter hook, tetapi `agentd` snapshot ini belum memasang IMAP/POP listener atau polling inbound email yang memasukkan pesan ke hook tersebut. Karena itu jangan mengiklankan email dua arah/inbound sebagai fitur aktif.

## Konfigurasi outbound

`agentd` membuat EmailGateway bila `EMAIL_FROM` di-set. Variabel yang tersedia:

```bash
export EMAIL_FROM=agent@example.com
export EMAIL_TO=you@example.com
export EMAIL_ALLOW=you@example.com
export SMTP_HOST=127.0.0.1
export SMTP_PORT=25
# Pilih 1 bila relay mengiklankan STARTTLS; 0 hanya untuk relay loopback tepercaya.
# Wajib 1 jika SMTP_USER/SMTP_PASS diaktifkan.
export SMTP_STARTTLS=1
# Opsional; username dan password harus dipasang berpasangan:
export SMTP_USER=relay-user
export SMTP_PASS='secret-from-environment'
dart run apps/agentd/bin/agentd.dart
```

Pengiriman wajib memiliki `meta.to` atau `EMAIL_TO`. Bila `EMAIL_ALLOW` tidak kosong, penerima harus ada di allowlist. Sender/recipient harus berupa mailbox tanpa whitespace/control character; subject menolak CR/LF, control character, dan nilai lebih dari 998 byte untuk mencegah SMTP command/header injection. Body dibatasi 100.000 karakter, dinormalisasi ke CRLF, dan baris yang dimulai titik di-dot-stuff sesuai SMTP DATA. Subjek default saat ini `agent_dart` kecuali `meta.subject` dikirim oleh caller. Respons server dibatasi `responseTimeout` (default 10 detik) dan seluruh transaksi setelah TCP connect memiliki `transactionTimeout` (default 60 detik); batas berlaku untuk multiline responses, flush dan STARTTLS handshake. Timeout membatalkan pembacaan dan menghancurkan socket.

## STARTTLS — perhatian keamanan

Kode memiliki dukungan STARTTLS opsional (`SMTP_STARTTLS=1`). Pada delta 10 November 2026, callback yang sebelumnya menerima semua sertifikat buruk telah dihapus. Upgrade memanggil `SecureSocket.secure(socket, host: host)` dan memakai validasi rantai sertifikat serta hostname bawaan Dart. Saat STARTTLS diminta, server wajib mengiklankan kapabilitas STARTTLS; Tiko menolak downgrade ke plaintext. Kredensial AUTH LOGIN wajib dipasangkan dan hanya boleh digunakan melalui STARTTLS. Respons SMTP untuk tahapan greeting/EHLO/TLS/auth/envelope/DATA divalidasi. Sertifikat self-signed/expired/tidak cocok harus ditolak kecuali CA terkait dipercaya oleh trust store host. Tetap uji koneksi SMTP pada host deployment sebelum mengaktifkan STARTTLS.

## Deployment yang disarankan sementara

Gunakan relay lokal yang dibatasi ke loopback (`127.0.0.1`) seperti msmtp/postfix/OpenSMTPD, dan konfigurasi relay tersebut untuk memvalidasi TLS upstream. Jika koneksi Tiko → relay lokal tidak memakai TLS, batasi ke loopback dan jangan membuka port relay ke jaringan publik. Simpan kredensial SMTP melalui environment/secret manager, bukan di YAML/README/Git.

## Status yang belum ada

- Inbound receiver IMAP/POP/SMTP server belum dipasang oleh `agentd` pada snapshot ini.
- SMTP live integration untuk sertifikat valid, tidak valid, expired, hostname mismatch, AUTH LOGIN, dan interoperabilitas relay nyata belum dijalankan. Fake SMTP tests mencakup STARTTLS downgrade, SMTP DATA/CRLF/dot-stuffing, input injection, kewajiban TLS bagi AUTH, server stall pada greeting, serta server stall setelah `MAIL FROM`; semua test baru belum dieksekusi tanpa Dart SDK.
- Email integration perlu test relay nyata (auth, STARTTLS, recipient allowlist, reconnect, dan bounce/error handling) sebelum dipakai untuk produksi.

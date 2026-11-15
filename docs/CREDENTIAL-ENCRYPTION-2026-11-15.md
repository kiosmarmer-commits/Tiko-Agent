# Enkripsi At-Rest CredentialManager (B-02 lanjutan)

Tanggal: 2026-11-15

## Latar

Audit eksternal 15 Nov (B-02) menandai `credentials.json` masih disimpan
sebagai plaintext JSON. Perbaikan pertama (PR #32) menambahkan tulis atomik,
`chmod 600`, dan kegagalan yang jujur, tetapi payload tetap plaintext.

## Perubahan

- `CredentialManager` kini menerima `passphrase` (default dari env
  `TIKO_SECRET_PASSPHRASE`). Saat passphrase tersedia (non-kosong):
  - Payload disegel dengan `SecretStore` (XChaCha20-Poly1305 AEAD di atas
    kunci Argon2id 19 MiB/t=2/p=1), format file `TSS2`, tulis atomik,
    permission 600.
  - File plaintext lama dimigrasi sekali saat `initialize()`: dibaca,
    disegel ulang, bytes plaintext diganti.
- Tanpa passphrase: perilaku lama (plaintext JSON + 0600) dipertahankan
  agar deployment existing tidak rusak.
- File tersegel dibuka tanpa passphrase -> `StateError` dengan pesan jelas
  (bukan dianggap korup).
- Passphrase salah -> kegagalan MAC -> `initialize()` gagal keras.

## Test

`packages/agent_security/test/credential_encryption_test.dart`:
roundtrip tersegel, migrasi plaintext, passphrase salah, dan file tersegel
tanpa passphrase.

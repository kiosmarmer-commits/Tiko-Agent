# Supply-Chain Hardening — 15 November 2026

Penguatan rantai pasok dependensi (rekomendasi #3 dari sesi hardening Hermes-parity): audit otomatis dependensi ter-pin, pemindaian kerentanan OSV, verifikasi integritas pin lockfile, pemeriksaan usia rilis, dan attestation SLSA untuk artifact build.

## Latar belakang

Skrip `scripts/verify_deps.py` lama (AGD-08 §4) hanya memeriksa **versi latest** dari daftar hardcoded 25 paket: tidak membaca `pubspec.lock`, tidak memeriksa kerentanan, tidak memverifikasi sha256, dan selalu exit 0 sehingga tidak pernah bisa menggagalkan CI.

## Implementasi

### 1. Audit dependensi ter-pin (`scripts/verify_deps.py`, ditulis ulang)

- **Pemindaian lockfile**: semua `pubspec.lock` di repo (root workspace + `apps/agent_flutter`) diparse; hanya paket `source: hosted` (pub.dev) yang diaudit — paket path/sdk/git dilewati. Deduplikasi per `(nama, versi)`.
- **Integritas pin**: `sha256` di lockfile dibandingkan dengan `archive_sha256` dari API pub.dev untuk versi yang sama. Mismatch → kegagalan (indikasi pin lockfile dimanipulasi atau versi tidak ada di registry).
- **Pemindaian OSV**: batch query ke `https://api.osv.dev/v1/querybatch` (ekosistem `Pub`, chunk ≤1000 query per permintaan). Kerentanan ditemukan → kegagalan, lengkap dengan saran versi perbaikan (`fixed`) yang diambil dari record OSV per ID.
- **Usia rilis**: versi ter-pin yang dipublikasikan < 7 hari (dapat dioverride via `--min-release-age` atau env `TIKO_MIN_RELEASE_AGE`) ditandai `TERLALU-BARU` — jendela kompromi supply-chain (pola `--min-release-age` npm 11, OpenSSF). Versi > 365 hari ditandai `TUAB` sebagai info. Keduanya peringatan, bukan kegagalan.
- **Discontinued**: paket yang ditandai discontinued di pub.dev → peringatan.
- **Fail-closed**: kegagalan jaringan OSV saat ada paket ter-pin diperlakukan sebagai kegagalan (bukan diam-diam lolos).
- **Exit code**: default non-strict selalu 0 (temuan hanya dicetak); `--strict` exit 1 bila ada kerentanan OSV, mismatch sha256, versi tidak dikenal di registry, atau OSV gagal.
- **Fallback**: bila tidak ada `pubspec.lock`, skrip kembali ke perilaku lama (cek latest daftar PKGS).

### 2. Job CI `supply-chain` (`.github/workflows/ci.yml`)

Job baru yang menjalankan:
1. `python3 scripts/test_verify_deps.py -v` — 15 test unit offline (fetcher di-monkeypatch): parsing lockfile, klasifikasi usia, chunking batch OSV, ekstraksi versi perbaikan, fail-closed saat OSV down, exit code strict.
2. `python3 scripts/verify_deps.py --strict --root .` — audit live terhadap lockfile yang di-track.

### 3. Attestation SLSA build provenance

Job `flutter-desktop` dan `android-apk` kini menghasilkan attestation build provenance (in-toto/SLSA, ditandatangani Sigstore via OIDC GitHub) dengan `actions/attest-build-provenance@v2`:
- Binary daemon `agentd` yang di-bundle ke aplikasi desktop (Linux/Windows/macOS).
- APK debug Android.

Permissions job terkait dinaikkan secara minimal: `contents: read`, `id-token: write`, `attestations: write`. Attestation dapat diverifikasi konsumen artifact dengan `gh attestation verify`.

## Hasil audit saat ini

Live run terhadap 31 paket ter-pin (dua lockfile): **0 kerentanan OSV, 0 mismatch sha256**, beberapa info usia (versi >365 hari) dan 1 peringatan rilis segar (`objective_c 9.6.4`, 3 hari) — semua non-blocking.

## Batasan

- Audit hanya mencakup paket hosted pub.dev; paket git/path/sdk tidak discan OSV.
- Keputusan upgrade versi tetap manual; skrip tidak mengubah lockfile.
- Attestation hanya tersedia untuk repo publik pada plan GitHub gratis.

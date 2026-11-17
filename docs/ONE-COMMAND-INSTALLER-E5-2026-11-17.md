# E5: Installer Sekali-Perintah (`install.sh`) — 2026-11-17

## Ringkasan

Menutup gap DX dari pertanyaan pengguna ("Hermes ada installer sekali-perintah
di terminal"): Tiko kini punya `install.sh` di root repository — satu perintah
yang mengurus semuanya, terinspirasi alur installer Hermes Agent.

```bash
git clone https://github.com/kiosmarmer-commits/Tiko-Agent.git
cd Tiko-Agent
bash install.sh
```

## Yang dilakukan installer (berurutan)

1. **Dart SDK otomatis** bila `dart` tidak ada / versi < 3.8: unduh Dart SDK
   stabil **pin 3.13.4** (sama dengan CI) untuk linux/macos x64/arm64 ke
   `~/.tiko/dart-sdk`, ekstrak (unzip atau fallback python3 zipfile), tambahkan
   PATH ke `.bashrc`/`.zshrc` bila belum ada. Unduhan via `curl` dengan
   fallback `python3 urllib`.
2. **`dart pub get`** seluruh workspace.
3. **Compile biner release** (`dart compile exe`): `tiko`, `agentd`,
   `agent_cli` → `build/`.
4. **Pasang ke prefix** (default `~/.local/bin`, opsi `--prefix`): salin +
   chmod +x.
5. **Smoke test** `--help` tiap biner + pemeriksaan PATH dengan instruksi
   eksplisit bila prefix belum di PATH.

Opsi: `--prefix DIR`, `--skip-dart-install`, `--help`. Argumen tak dikenal
ditolak (exit 1, fail-closed).

## Yang TIDAK dilakukan (jujur, tercetak di header script & output)

- Tidak memasang Flutter SDK / membangun client Flutter
  (`apps/agent_flutter` butuh Flutter 3.47.5 — jalur manual di INSTALL.md).
- Tidak mengonfigurasi provider LLM/API key — installer menampilkan langkah
  berikutnya (`tiko setup --provider mock`, `tiko doctor`, `tiko chat`).
- Tidak menjalankan apa pun sebagai root; tidak menyentuh PATH sistem.

## Integrasi CI

Step CI **"Compile executable entrypoints" diganti** dengan
"Compile executables via one-command installer (smoke)": CI kini menjalankan
`bash install.sh --skip-dart-install --prefix "$HOME/.local/bin"` lalu
memverifikasi `build/{tiko,agentd,agent_cli}` executable dan biner terpasang
di prefix — coverage sama (3 compile) + jalur installer teruji di setiap push.

## Pengujian

- Sandbox lokal: `bash install.sh --skip-dart-install --prefix /tmp/tiko-prefix`
  hijau end-to-end (pub get → 3 compile → pasang → 3 smoke --help →
  peringatan PATH).
- `--help` menampilkan dokumen header; argumen tak dikenal → exit 1.
- `bash -n` (syntax) bersih.
- CI: step installer smoke menggantikan step compile lama (23 check tetap).

# Penuntasan Catatan Batasan (Deferred Items) — 12 November 2026

Batch ini menuntaskan tiga catatan batasan yang tertunda dari batch P0/P1/P2
audit eksternal. Semua perubahan diverifikasi dengan `dart analyze
--fatal-warnings` + `dart test` lokal penuh (semua package lulus), lalu CI.

## 1. Subset skema tool dinamis di loop context (menuntaskan P2-2)

Sebelumnya `tool_search` tersedia sebagai meta-tool, tetapi ContextBuilder
tetap mengirim **semua** skema tool ke model setiap turn.

Sekarang `RuntimeContext` (`tiko_runtime_internals.dart`) menerapkan subset
dinamis:

- Bila jumlah specs (setelah `toolFilter`) ≤ `toolSubsetThreshold`
  (default 24), perilaku lama dipertahankan (semua specs dikirim).
- Di atas threshold, hanya `toolSubsetK` (default 20) specs paling relevan
  dengan teks user yang dikirim, diranking via `rankToolSpecs()`
  (agent_tools, P2-2). `tool_search` **selalu** disertakan agar model bisa
  menarik skema lain on-demand; bila ranking kosong (tidak ada token cocok),
  fallback ke specs pertama secara urutan registry.
- System prompt diberi catatan eksplisit saat subset aktif.
- **Eksekusi tidak terpengaruh**: gate dan registry tetap mengenal surface
  penuh, jadi tool di luar subset tetap bisa dipanggil bila model memanggil
  namanya (skema hanya memengaruhi apa yang dilihat model).

Config baru (`TikoConfig`, YAML `agent.tool_subset_threshold` /
`agent.tool_subset_k`): default 24 / 20.

Test: `packages/tiko_runtime/test/tool_subset_test.dart` (6 test).

## 2. `modelTier` per-role diteruskan ke team runner (menuntaskan catatan P0)

Catatan batch P0: "pemilihan tier terjadi di `Router.route()` berbasis teks,
bukan parameter panggilan" — `AgentSpec.modelTier` diabaikan.

Sekarang:

- `AgentConfig` (agent_core) punya `preferredTier` (int?, default null);
  `AgentLoop.handle()` meneruskannya ke `Router.route(preferredTier:)`.
- `Router.route(text, session, {preferredTier})`: bila non-null, tier hasil
  keputusan teks **dioverride** (clamp 0–3) sementara keputusan
  needTools/risk/complexity tetap dari teks; alasan routing mencatat
  `preferred tier=N (call parameter)`.
- Team runner (`AgentTeamTool` di tiko_runtime) meneruskan
  `preferredTier: modelTierToRouterTier(agent.modelTier)`.
- `modelTierToRouterTier()`: `light|fast|eco`→1, `standard|default`→2,
  `heavy|reasoning|deep|premium`→3, **nilai tidak dikenal → null**
  (routing teks tetap berlaku; fail-open ke perilaku existing, tidak pernah
  ke rute rusak).

Test: `packages/agent_core/test/router_preferred_tier_test.dart` (4 test,
termasuk spy router membuktikan loop meneruskan `config.preferredTier`) dan
`tool_subset_test.dart` (pemetaan tier).

## 3. Mode voice `aead_xchacha20_poly1305` (menuntaskan P1-4 sepenuhnya)

P1-4 lama menghadirkan `xsalsa20_poly1305` (NaCl secretbox). Kini mode AEAD
modern Discord juga didukung:

- Modul baru `packages/agent_gateway/lib/src/xchacha20_aead.dart` (pure Dart):
  - ChaCha20 block/stream (RFC 8439, nonce 96-bit, counter mulai 1).
  - `hchacha20()` subkey derivation (draft-irtf-cfrg-xchacha §2.2).
  - `aeadChaCha20Poly1305Seal/Open` (RFC 8439 §2.8: otk dari block 0,
    tag Poly1305 atas `pad16(AAD) || pad16(cipher) || len(AAD) || len(cipher)`,
    verifikasi tag constant-time).
  - `aeadXchacha20Poly1305Seal/Open` (nonce 24-byte: subkey dari
    `nonce[0:16]`, nonce AEAD `00000000 || nonce[16:24]`).
- `AeadXchacha20Poly1305Encryptor` (mode `aead_xchacha20_poly1305`) di
  `discord_voice.dart`: nonce 24-byte = RTP header (12B) + 12 zero byte
  (deterministik, derivasi sama seperti mode xsalsa), RTP header dipakai
  sebagai **AAD** sehingga tampering header terdeteksi oleh tag. Layout paket
  tetap `header || ciphertext || tag(16)`.
- Poly1305 dipakai ulang dari `nacl_secretbox.dart` via wrapper publik
  `naclPoly1305()`.

Verifikasi vektor resmi (bukan roundtrip saja):
- HChaCha20 draft-irtf-cfrg-xchacha §2.2.1 (key `000102..1f`, nonce
  `000000090000004a0000000031415927` → subkey `82413b42..26d3ecdc`).
- AEAD_XCHACHA20_POLY1305 draft §A.3.1 (ciphertext `bd6d179d..b52e`, tag
  `c0875924c1c7987947deafd8780acf49`) — memvalidasi seluruh komposisi
  HChaCha20 + ChaCha20 + Poly1305 + framing AEAD.

Test: `packages/agent_gateway/test/xchacha20_aead_test.dart` (8 test:
vector, tamper cipher/AAD ditolak, roundtrip, kontrak encryptor).

## Cara uji manual

```bash
export PATH=<dart-sdk>/bin:$PATH
cd packages/agent_gateway && dart test test/xchacha20_aead_test.dart
cd ../agent_core && dart test test/router_preferred_tier_test.dart
cd ../tiko_runtime && dart test test/tool_subset_test.dart
```

## Batasan yang tetap terdokumentasi (belum dikerjakan)

- Cost subagent tetap 0.0 (belum ada pricing table per model).
- Cancellation subagent via wall-clock budget; cancellation token kooperatif
  per-tool belum ada.
- ACP filesystem/permission surface (`fs/read_text_file`,
  `fs/write_text_file`) belum — butuh kontrak permission request ke client
  editor.
- Out-of-scope permanen: agent manager UI (P2-5), LSP (P2-7), real-device QA
  (P2-8).

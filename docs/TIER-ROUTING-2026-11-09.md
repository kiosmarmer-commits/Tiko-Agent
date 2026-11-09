# Perbaikan: Tier Routing Adaptif (providers.tiers)

- Tanggal: 2026-11-09
- Repo: `kiosmarmer-commits/Tiko-Agent` (branch `main`)
- Bloker: prioritas feat #1 sesi "Lanjutkan semua perbaikan menurut prioritas" (ALG-06)
- Jejak audit: feat `c9631b80` ("feat(routing): tier routing adaptif — pemetaan providers.tiers di-wire ke Router")

## Masalah

`Router` sejak awal sudah menerima pemetaan `tierProviders` dan memakainya di `route()` (`prefer = tierProviders[tier] ?? defaultProviderId`), tetapi pemetaan itu tidak pernah bisa diisi dari config: `TikoConfig` tidak punya skema `providers.tiers` dan `TikoRuntime` membangun `Router` tanpa tier. Akibatnya semua tier (ringan/sedang/berat) selalu jatuh ke `default_chat` — model besar tidak pernah bisa dialokasikan hanya untuk tugas berat, dan sebaliknya.

## Desain

1. **Skema `providers.tiers`** (`packages/tiko_runtime/lib/src/tiko_config.dart`) — mapping tier `1|2|3` ke id provider. Validasi fatal: tier di luar 1..3, value bukan string kosong, provider tidak terdefinisi, atau provider disabled → `ConfigIssue` dengan path `providers.tiers.<key>`; nilai non-mapping → issue di `providers.tiers`. Default (tanpa blok) = map kosong.
2. **Field `TikoConfig.tierProviders`** — ctor default `const {}`, dipass saat parse; `setupYaml` kini meng-emit `tiers: {}` agar config hasil setup tetap round-trip.
3. **Wiring runtime** — getter `_router` di `TikoRuntime` mengoper `tierProviders: config.tierProviders` ke `Router`, di antara `defaultProviderId` dan `decision`.
4. **Observabilitas** — `Router.explain()` (CLI `tiko route explain`) menampilkan `tier_providers` sebagai mapping string, sehingga pemetaan aktif bisa diaudit tanpa membaca file config.
5. **Contoh ter dokumentasi** — `config/agent.yaml` membawa komentar contoh pemetaan tier (dinonaktifkan, supaya default shipped config tetap mock-only).

Sifat pemilihan tidak berubah: `route()` tetap memilih tier dari decision model (bila aktif) atau heuristik kompleksitas, lalu `prefer = tierProviders[tier] ?? defaultProviderId`; provider preferensi tetap di-skip bila circuit-nya open (fallback ke provider sehat berikutnya).

## Matriks test

| Test | Yang diverifikasi |
| --- | --- |
| `tiko_config_test.dart` — "providers.tiers memetakan tier ke provider dan divalidasi" | mapping valid (1→kecil, 3→besar, tier 2 tidak dipaksa ada); tier 0 dan provider hantu → issue path `providers.tiers.0`/`.2`; `tiers: oops` (scalar) → issue di `providers.tiers` |
| `router_fallback_test.dart` — "tier routing memilih provider sesuai keputusan decision model" | decision `berat` → tier 3 → provider `besar`; decision `ringan` → tier 1 → provider `kecil` (via `_FixedDecision` stub) |
| `router_fallback_test.dart` — "tier tanpa pemetaan jatuh ke provider default" | tanpa `tierProviders`, tier 3 tetap dirutekan ke default, tidak error |
| `router_fallback_test.dart` — "explain menampilkan pemetaan tier" | `explain()` mengembalikan `tier_providers` berisi pemetaan aktif |

`_FixedDecision` adalah stub `DecisionProvider` deterministik yang menjawab `kompleksitas` sesuai konstruktor dan `noul 0.0` untuk pertanyaan noul — memungkinkan pengujian pemetaan tier tanpa decision model nyata.

## Keterbatasan

- Pemetaan hanya per-tier (1/2/3); tidak bisa per-sesi, per-channel, atau per-skill.
- Dengan decision model disabled (default shipped), tier ditentukan heuristik kompleksitas, bukan model — pemetaan tetap bekerja tapi but (bila menginginkan penilaian nyata).
- `tiko config set` belum punya setter khusus untuk `tiers`; untuk sekarang edit YAML langsung lalu `tiko config validate`.

## Status

Selesai; menunggu konfirmasi CI hijau di HEAD setelah commit docs ini.

# Laporan: Circuit Breaker Half-Open Single-Probe + Fallback All-Unhealthy Deterministik — 2026-11-09

## 1. Masalah

Blokir rilis: "Circuit-breaker single-probe half-open behavior and deterministic handling when every provider is unhealthy." Audit `packages/agent_providers/lib/src/circuit_breaker.dart` menemukan:

1. **Half-open tidak eksklusif.** Getter `isOpen` menulis `_halfOpen = true` (efek samping di getter) lalu mengembalikan `false` "allow one trial" — tetapi SETIAP pemanggil berikutnya juga lolos. Satu provider yang sakit bisa kena banjir traffic penuh setelah jendela open berakhir, bukan satu probe.
2. **Half-open bisa macet selamanya.** Bila tidak ada verdict (recordSuccess/recordFailure tidak pernah dipanggil — misalnya stream dibatalkan pemanggil), breaker menginjak fase half-open tanpa batas dan semua traffic mengalir ke provider yang masih sakit.
3. **Semua provider unhealthy tidak deterministik.** `FallbackLlmProvider` melaporkan kondisi "semua breaker terbuka, tidak ada request yang dieksekusi" sebagai `fallback_exhausted` generik ("semua provider gagal: circuit breaker open for …"). Caller tidak bisa membedakan "coba lagi nanti" dari "provider benar-benar error saat dieksekusi".
4. **Getter bermutasi.** `state` dan `isOpen` saling memengaruhi state internal tergantung urutan pemanggilan — hasil bisa berbeda hanya karena sebuah getter dibaca lebih dulu.

## 2. Desain

### 2.1 `CircuitBreaker`

- Enum baru `BreakerPhase { closed, open, halfOpen }` — fase dihitung murni dari `_openedAt` vs `openDuration` dengan clock yang dapat disuntik (`DateTime Function()? clock`, default `DateTime.now().toUtc()`), tanpa efek samping sama sekali.
- `tryAcquire()` menggantikan pola "isOpen lalu eksekusi":
  - closed → diizinkan;
  - open → ditolak;
  - half-open → hanya pemanggil PERTAMA yang mendapat slot probe (`_probeInFlight`); pemanggil lain ditolak seolah breaker masih terbuka (fail-closed).
- Verdict: `recordSuccess()` menutup breaker penuh; `recordFailure()` pada half-open langsung membuka ulang jendela penuh (timestamp baru); dari closed, pembukaan tetap mengikuti `failureThreshold`.
- `releaseProbe()` melepas slot probe tanpa verdict sehingga half-open tidak pernah macet memegang satu-satunya slot.
- Kompatibilitas: `isOpen` tetap ada (true hanya pada open penuh), `state` tetap mengembalikan string `'closed' | 'open' | 'half_open'` — kini akurat segera setelah jendela berakhir tanpa perlu dipancing getter lain.

### 2.2 `BreakerLlmProvider`

- `chat()` memakai `tryAcquire()`; ditolak → satu `LlmError` kode `breaker_open` tanpa menyentuh provider.
- Verdict dikumpulkan di `finally`: error event/throw → `recordFailure`; stream selesai tanpa error → `recordSuccess`; stream dibatalkan sebelum verdict → `releaseProbe()` (state tidak berubah).

### 2.3 `FallbackLlmProvider` — deterministik saat semua unhealthy

- Setiap `LlmError` kode `breaker_open` dihitung (`breakerBlocked`). Bila SEMUA provider menolak karena breaker terbuka (tidak ada satu pun eksekusi sungguhan), hasilnya `LlmError` kode baru **`all_breakers_open`** dengan pesan eksplisit. Kondisi campuran (satu breaker terbuka, satu gagal dieksekusi) tetap `fallback_exhausted`.

## 3. Matriks test (`packages/agent_providers/test/circuit_breaker_test.dart`, baru)

| Kasus | Ekspektasi |
|---|---|
| closed | `tryAcquire` selalu true |
| threshold 3 kegagalan | state `open`, panggilan berikut ditolak |
| half-open | tepat satu slot probe; probe kedua ditolak; gagal → buka ulang; sukses → closed |
| `releaseProbe` | slot bebas tanpa verdict, probe berikutnya diizinkan |
| `BreakerLlmProvider` breaker terbuka | ditolak cepat, provider tidak disentuh (attempts tetap), kode `breaker_open` |
| probe half-open via provider | provider dieksekusi tepat sekali, gagal → open lagi |
| fallback + provider sehat | sukses tanpa `LlmError` |
| dua breaker terbuka | ronde pertama `fallback_exhausted`, ronde kedua `all_breakers_open` |
| campuran breaker + kegagalan nyata | tetap `fallback_exhausted` |

Semua test deterministik lewat clock suntikan — tidak ada `sleep`/timing race.

## 4. Keterbatasan & tindak lanjut

1. Probe half-open masih satu permintaan penuh; tidak ada ramp-up bertahap (satu probe sukses langsung menutup breaker). Sesuai blokir "single-probe"; ramp-up bisa ditambah bila terbukti perlu.
2. `Router` di `agent_core` punya mekanisme kesehatan per-provider sendiri (`ProviderHealth`) yang tidak memakai kelas ini — penyatuan keduanya adalah pekerjaan lanjutan terpisah agar tidak mengubah perilaku routing dalam satu patch.
3. `embed()` tidak dibungkus breaker (mengikuti kontrak lama).

## 5. Jejak audit

- Feat: `packages/agent_providers/lib/src/circuit_breaker.dart` (tulis ulang) + `test/circuit_breaker_test.dart` (baru, 9 test) — commit `fb30dbf`.
- Tanpa dependensi baru (AGD-08); API lama (`isOpen`, `state` string, `recordSuccess`, `recordFailure`) dipertahankan untuk kompatibilitas.
- Verifikasi: CI GitHub Actions (`dart analyze --fatal-infos --fatal-warnings` + test seluruh workspace member + smoke CLI/agentd) pada HEAD docs ini.

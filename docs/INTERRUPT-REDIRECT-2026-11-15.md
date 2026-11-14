# Interrupt & Redirect — 2026-11-15

Paritas Hermes (gap #9 dari daftar sisa): pesan baru yang datang saat sesi
sedang memproses turn **tidak lagi ditolak** — turn aktif diinterupsi secara
kooperatif dan pesan baru langsung diproses.

## Perilaku

- Sebelumnya: `chatWithStatus` pada sesi sibuk → "Sesi masih memproses pesan
  sebelumnya."
- Sekarang: runtime membatalkan token turn aktif (`CancellationRegistry`,
  kooperatif — loop mengecek di iteration/tool boundary), menunggu lock sesi
  lepas (bounded, default 60s), lalu memproses pesan baru di turn berikutnya.
- Turn baru menerima system note internal: *"Turn sebelumnya diinterupsi oleh
  pesan baru dari pengguna..."* sehingga model mengarahkan ulang tanpa
  melanjutkan rencana lama.
- Turn lama berakhir dengan "Turn dibatalkan atas permintaan." (sukses=false)
  di pemanggilnya.
- Event bus: `turn.interrupted` (berisi session & channel) — terlihat di web
  UI/Flutter.
- Fallback aman: bila turn lama tidak juga selesai dalam `waitTimeout`
  (tool yang mengabaikan cancellation), pesan baru kembali ditolak dengan
  pesan sibuk.

## Konfigurasi

```yaml
agent:
  interrupt_redirect: true   # default true; false = perilaku lama (tolak)
```

## Komponen

- `packages/tiko_runtime/lib/src/turn_redirect.dart` —
  `TurnRedirectCoordinator.interruptAndWait` (cancel + poll lock bounded).
- `TikoRuntime.chatWithStatus` — jalur sibuk kini mencoba redirect dulu;
  parameter `interruptNote` meneruskan konteks interupsi ke `RuntimeContext`.
- `RuntimeContext.build` — inject system note interupsi ke messages.

## Test

- `packages/tiko_runtime/test/turn_redirect_test.dart` (3): menunggu lock
  lepas, timeout mengembalikan false, selesai tanpa cancel saat lock cepat
  bebas.
- `packages/tiko_runtime/test/interrupt_redirect_e2e_test.dart` (2): e2e
  dengan provider OpenAI-compat palsu — pesan kedua memotong turn pertama di
  tool boundary, turn kedua sukses diproses, event `turn.interrupted`
  teremit; dan pesan berurutan saat idle tidak memicu interupsi.

## Verifikasi

- `dart analyze --fatal-warnings` bersih; seluruh test tiko_runtime lulus.
- `bash scripts/validate.sh` — VALIDATION PASS.

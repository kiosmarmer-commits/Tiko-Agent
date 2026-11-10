# 02 — Provider AI, Decision Model dan Routing

> **Catatan status:** dokumen referensi ini berawal dari snapshot historis `69b6da421bf2a4682dce19e05d1ea608607250be`. Baseline GitHub `main` yang terakhir diverifikasi pada 10 November adalah `dfa7a0ecbd830fd9ecaa50f37145bb27351f5711`; bundle implementasi lokal sesudah baseline itu dijelaskan di `STATUS-2026-11-10.md` dan belum lolos Dart/Flutter CI. Gunakan source sebagai kontrak implementasi dan dokumen ini sebagai panduan arsitektur, bukan bukti validasi bundle.

**Snapshot:** `69b6da421bf2a4682dce19e05d1ea608607250be`.

## 1. Adapter yang benar-benar tersedia

`ProviderFactory` (`packages/tiko_runtime/lib/src/provider_factory.dart`) membangun adapter berikut berdasarkan `providers.chat`:

| `type` config | Implementasi | Peran | Kebutuhan |
|---|---|---|---|
| `mock` | `MockLlmProvider` | Default/test/offline deterministic | Tidak perlu secret |
| `openai_compat` | `OpenAiCompatProvider` | OpenAI API dan server kompatibel OpenAI seperti Ollama `/v1` | `base_url`, `model`, opsional `api_key: env:VAR` |
| `ollama_native` | `OllamaNativeProvider` | API native Ollama | Ollama host/model |
| `anthropic` | `AnthropicProvider` | Claude API | `api_key: env:VAR` |
| `gemini` | `GeminiProvider` | Gemini API | `api_key: env:VAR` |

Adapter HTTP ada di `packages/agent_providers`; dependency langsung package tersebut adalah `http`, bukan `openai_dart`, `ollama_dart`, `anthropic_sdk_dart`, atau `googleai_dart`. Jangan menambahkan SDK ke registri dependency sebagai dependency runtime tanpa mengubah manifest.

`providers.default_chat` harus menunjuk ke provider yang didefinisikan dan enabled. Template `config/agent.yaml` menggunakan `mock` agar setup awal tidak membutuhkan API key atau server lokal.

## 2. DecisionProvider

Decision model dibangun terpisah dari chat provider. `ProviderFactory.buildDecision()` memakai `SystemOneDecisionProvider` bila `decision.enabled` aktif. Bila disabled, router dapat menggunakan `LlmJsonDecisionProvider` hanya bila `decision.llm_fallback` aktif dan provider fallback tersedia; bila tidak, routing menggunakan heuristic.

Decision payload yang saat ini diminta Router:

- `butuh_tool` — `NoulQuestion`;
- `berbahaya` — `NoulQuestion`;
- `kompleksitas` — choice `ringan`, `sedang`, `berat`.

Threshold default `DecisionThresholds`: butuh tool 0,6; minta konfirmasi untuk risk 0,5; reject critical pada 0,9. Kode/permission gate tetap otoritas terakhir; hasil decision model bukan izin tool.

## 3. Tier routing

`providers.tiers` memetakan tier `1`, `2`, `3` ke provider ID. Config parser menolak tier di luar 1–3, provider tidak terdefinisi, provider disabled, dan bentuk YAML yang salah. Bila map kosong, semua tier menggunakan default provider.

Perilaku saat ini:

1. Slash command diarahkan ke tier 0 dan default provider.
2. Bila DecisionProvider aktif dan sukses, `kompleksitas` dan `butuh_tool` menentukan tier: ringan tanpa tool → 1; ringan dengan tool → 2; sedang → 2; berat → 3.
3. Bila DecisionProvider tidak aktif, heuristic keyword menentukan kebutuhan tool; panjang pesan `> 200` karakter menjadi heuristic berat, selainnya ringan; tier menjadi 2 bila perlu tool, jika tidak tier 1.
4. Bila DecisionProvider melempar error, `needTools` kembali ke heuristic; kompleksitas awal tetap sedang, sehingga tier efektif 2.
5. Provider preference dicoba jika selectable; jika tidak, Router menilai provider lain berdasarkan kemampuan tool, ID lokal, kegagalan dan latensi. Fallback chain mencoba ID tersisa tanpa mengulang provider yang sudah dicoba pada request itu.

Gunakan `tiko route explain --task "..."` untuk melihat hasil route, tier mapping, provider health dan fallback events.

Contoh config:

```yaml
providers:
  default_chat: local_small
  tiers:
    1: local_small
    2: local_small
    3: cloud_reasoning
  chat:
    local_small:
      type: ollama_native
      base_url: http://127.0.0.1:11434
      model: qwen2.5:3b
    cloud_reasoning:
      type: openai_compat
      base_url: https://api.example.com/v1
      model: model-name
      api_key: env:AI_API_KEY
```

Nama endpoint/model di atas adalah contoh; sesuaikan dengan provider yang benar-benar digunakan.

## 4. Kesehatan provider dan breaker

Implementasi memiliki dua lapisan, tidak boleh disatukan dalam dokumentasi:

- `ProviderHealth` pada `agent_core.Router`: closed/open/half-open, health/latency scoring, satu probe half-open melalui `tryAcquire`, fallback selection dan event.
- `CircuitBreaker` pada `agent_providers`: default 3 kegagalan beruntun membuka breaker 60 detik, lalu satu probe half-open. `BreakerLlmProvider` mencatat verdict ketika stream sukses/gagal dan melepas slot bila stream dibatalkan tanpa verdict. `FallbackLlmProvider` membedakan `all_breakers_open` dari kegagalan eksekusi gabungan.

Breaker wrapper ini tidak otomatis membungkus `embed()`; Router health dan provider wrapper juga belum memakai satu state object bersama.

## 5. Embedding

Memory embedder opsional dikonstruksi dari `memory.embed` melalui `OllamaEmbedder`. Jika tidak diaktifkan, jalur vector recall dormant dan FTS/BM25 menjadi sumber retrieval utama. Aktifkan hanya setelah model embedding dan endpoint yang sesuai tersedia.

## 6. Environment dan rahasia

API key pada config wajib berbentuk `env:NAMA_VAR`. Nilai secret dibaca dari environment saat runtime. Jangan menulis token/API key mentah di YAML, README, log, contoh commit, atau test fixture.

## 7. Keterbatasan verifikasi

CI memakai mock untuk smoke CLI; CI hijau bukan bukti bahwa akun provider cloud, Ollama lokal, Laya/Jev eksternal, atau embedding server telah diuji end-to-end. Uji koneksi provider nyata secara terpisah dan jangan mencantumkan hasil akurasi model tanpa dataset dan hasil evaluasi yang dapat diulang.

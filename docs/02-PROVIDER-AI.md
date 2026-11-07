# 02-PROVIDER-AI

- **ID dokumen:** AGD-02
- **Bergantung pada:** AGD-01

## 1. LlmProvider (model chat)
| Adapter | Paket Dart | Versi terverifikasi | Status | Dipakai untuk |
|---|---|---|---|---|
| OpenAI-compatible | `openai_dart` | 11.0.1 | ✅ | OpenAI, OpenRouter, Ollama `/v1`, LM Studio, llama.cpp server, Groq (via `baseUrl`) |
| Ollama native | `ollama_dart` | 4.0.0 | ✅ | Fitur khas Ollama (model mgmt, think, embed) |
| Anthropic | `anthropic_sdk_dart` | 9.0.0 | ✅ | Claude API |
| Gemini | `googleai_dart` | 13.0.0 | ✅ | Gemini API |
| Mistral | `mistralai_dart` | ⚠️ | ⚠️ | Opsional |

Sumber versi: halaman skor pub.dev paket `dart_mcp_core` (kolom "Latest", analisis Dart 3.13.5),
kemudian dikonfirmasi lewat monorepo `davidmigloz/langchain_dart` (paket-paket ini dirilis dari sana).
> Catatan: dukungan `baseUrl` kustom pada `openai_dart` dan nama field tepatnya wajib dicek di dokumentasi
> sebelum implementasi (TASK-02-01).

**Keputusan DEC-02:** jangan memakai umbrella `langchain` untuk loop inti. Alasan: abstraksi ekstra,
perubahan versi besar yang cepat (lihat lompatan versi klien di atas). Boleh dipakai sebagai referensi
atau untuk komponen terisolasi.

### Kapabilitas yang dideteksi (P-06)
```dart
class Capabilities {
  final bool toolCalling, vision, logprobs, streaming, jsonSchemaOutput;
  final int maxContext;
}
```
Cara deteksi: konfigurasi per model + probe sekali (kirim tool dummy), simpan hasil di tabel `kv`.

## 2. Routing model (tier)
| Tier | Model | Kapan |
|---|---|---|
| T0 | Aturan/regex (tanpa model) | Perintah slash, jadwal sederhana |
| T1 | DecisionProvider (Laya/Nimble/Jev) | Klasifikasi, guardrail, router |
| T2 | LLM lokal kecil (0.6B–8B) | Obrolan ringan, ringkasan, ekstraksi |
| T3 | LLM lokal besar / cloud | Perencanaan, kode, tool calling kompleks |

Aturan: mulai dari tier terendah yang memenuhi; naikkan bila confidence < ambang atau hasil gagal validasi.
Fallback berantai dengan circuit breaker: 3 kegagalan berturut-turut → buka 60 detik → coba provider berikutnya.

## 3. DecisionProvider (model keputusan bertipe)
Jev dan sejenisnya **tidak menghasilkan teks**; mengembalikan `Choice`, `Score`, atau `Noul` (yes/no/unknown)
beserta probabilitas.

| Opsi | Jalan di | Lisensi | Status | Catatan |
|---|---|---|---|---|
| **Jev** (TypeSafe AI) | Hosted: `POST https://api.typesafe.ai/v1/systemone`; Vercel AI Gateway `typesafe-ai/jev`; Cloudflare `typesafe/jev` | Proprietary | ✅ | Model `jev-1.13.0`/`jev-latest`; tanpa streaming; $0,042/juta token input; early access |
| **Laya** (Convai/NandhaKishorM) | Lokal Python (`pip install laya`, `laya-serve`) | Apache-2.0 | ✅ v0.4.6 | Checkpoint multilingual 322M (100+ bahasa), typed-decisions 421M; server kompatibel Jev; ada ekstra ONNX dan MCP |
| **Bespoke Nimble** | Lokal via Ollama (`nimble`) atau server System One | Terbuka | ✅ (dokumen LiteLLM) | Model sebagai classifier |
| LocalJev, jeff, SemIf/OpenJev | Lokal | MIT/lainnya | ⚠️ (dari blog) | Verifikasi repo sebelum dipakai |
| LLM + JSON schema (fallback) | Ollama/llama.cpp | — | ✅ pola umum | Paksa keluaran terbatas; baca probabilitas bila logprobs tersedia |

**Peringatan akurasi (EVIDENCE):** laporan Laya sendiri menunjukkan model Inggris turun drastis lintas bahasa
(MASSIVE: 0,783 → 0,306) dan varian multilingual 0,451 pada tugas yang sama; ulasan pihak ketiga menyebut
Jev 0,966 vs 0,704 untuk peserta open source terbaik pada 49 tugas. Jadi **uji sendiri pada bahasa Indonesia**.

### Antarmuka Dart (HTTP System One)
```dart
class SystemOneDecisionProvider implements DecisionProvider {
  SystemOneDecisionProvider(this.baseUrl, this.model, {this.apiKey, Dio? dio});
  final String baseUrl, model; final String? apiKey;

  @override
  Future<DecisionResult> decide(String state, Map<String, Question> qs) async {
    final res = await _dio.post('$baseUrl/v1/systemone',
      options: Options(headers: {if (apiKey != null) 'Authorization': 'Bearer $apiKey'}),
      data: {'model': model, 'state': state, 'questions': qs.map((k, q) => MapEntry(k, q.toJson()))});
    return DecisionResult.fromJson(res.data);
  }
}
```
Bentuk jawaban (dari dokumen LiteLLM): `answers.<nama>.{type, choice, probabilities, confidence}`.
> ⚠️ Nama field request (`state`) dan skema auth belum diverifikasi dari `docs.typesafe.ai/api`
> (TASK-02-02). Laya `laya-serve` mengklaim kompatibel dengan `/v1/systemone`; verifikasi dengan `curl`.

### Kebijakan ambang (threshold)
| Pertanyaan | Tipe | Aksi |
|---|---|---|
| `berbahaya` | Noul | P(yes) ≥ 0.5 → minta konfirmasi user; ≥ 0.9 → tolak |
| `butuh_tool` | Noul | ≥ 0.6 → aktifkan tool calling |
| `kompleksitas` | Choice {ringan, sedang, berat} | pilih tier T2/T3 |
| `kepastian` | Score | rendah → naik tier atau tanya ulang user |
Ambang disimpan di config; **model hanya menyarankan, kode yang memutuskan**. Untuk keamanan, allowlist tetap
lapisan utama (lihat AGD-07).

## 4. Model embedding dan lainnya
| Peran | Kandidat | Status |
|---|---|---|
| Embedding multibahasa | `bge-m3`, `multilingual-e5-*` via Ollama/ONNX | ⚠️ cek ketersediaan tag di Ollama |
| Reranker | `bge-reranker-*` | ⚠️ |
| STT | whisper.cpp, Vosk | ⚠️ |
| TTS | Piper, `flutter_tts` | ⚠️ |
| Model kecil HP RAM 2 GB | Qwen3-0.6B (kandidat dari riset pengguna) | ⚠️ uji kecepatan dan pemahaman Indonesia |
Runtime lokal: **Ollama v0.40.6 (2026-10-16), MIT** ✅ — mendukung tool calling, structured outputs, vision,
API kompatibel OpenAI dan Anthropic (sumber: developersdigest.tech, rujuk docs.ollama.com). llama.cpp ⚠️.

## 5. Task
| ID | Task | Kriteria selesai |
|---|---|---|
| TASK-02-01 | Adapter OpenAI-compat + streaming + tool calling | Lulus tes terhadap Ollama lokal |
| TASK-02-02 | Verifikasi spesifikasi `/v1/systemone` (Jev + laya-serve) | Dokumen contoh request/response nyata |
| TASK-02-03 | Adapter Anthropic dan Gemini | Tes smoke dengan kunci API |
| TASK-02-04 | Circuit breaker + fallback chain | Tes simulasi kegagalan |
| TASK-02-05 | Set evaluasi 50 kalimat Indonesia untuk router/guardrail | Laporan akurasi per model |

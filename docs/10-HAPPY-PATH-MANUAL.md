# Happy-Path Manual: Browser, Image Generation, Voice (P1-10)

Dokumen ini adalah panduan uji manual jalur happy-path untuk tiga kelompok
fitur multimodal. Semua nama env/config diverifikasi terhadap source pada
saat dokumen ditulis (lihat referensi file di tiap bagian).

Label status mengikuti konvensi `00-INDEX.md`:
**Implemented, conditional** = kode + wiring ada, aktif hanya bila
config/env/software host tersedia.

---

## 1. Browser

### 1.1 Browser lokal — `cdp_browser` (Implemented, conditional)

Sumber: `packages/agent_tools/lib/src/cdp_browser.dart`,
registrasi `packages/tiko_runtime/lib/src/tiko_runtime.dart` (`..register(CdpBrowserTool())`).

**Prasyarat:**

- Chromium/Chrome terpasang. Client mencari executable di urutan:
  1. `TIKO_CHROME_PATH` (env)
  2. `CHROME_PATH` (env)
  3. `CHROMIUM_PATH` (env)
  4. Path kandidat bawaan (`/usr/bin/google-chrome`, `/usr/bin/chromium`,
     `/snap/bin/chromium`, path macOS/Windows — lihat `_candidates`).
- Jika tidak ditemukan: set `TIKO_CHROME_PATH` ke path executable.

**Cara uji manual:**

```bash
export TIKO_CHROME_PATH=/usr/bin/chromium   # sesuaikan
cd apps/tiko && dart pub get && dart run bin/tiko.dart
```

Lalu di sesi chat:

```text
> buka https://example.com dengan browser dan baca isinya
```

atau panggil tool langsung (aksi: `navigate | evaluate | read_text | close`):

```text
> pakai cdp_browser action=navigate url=https://example.com
> pakai cdp_browser action=read_text
```

**Ekspektasi:** agent menjalankan Chromium headless (`--headless=new`),
navigate sukses, `read_text` mengembalikan teks halaman dalam envelope
untrusted. Browser otomatis ditutup saat sesi/tool selesai.

Alternatif tanpa launcher: set `wsEndpoint` (CDP WebSocket) bila Anda
menjalankan Chrome sendiri dengan `--remote-debugging-port`.

### 1.2 Cloud browser — `cloud_browser` (Implemented, conditional)

Sumber: `packages/agent_tools/lib/src/cloud_browser_tool.dart`,
`browser_backends.dart`, wiring `tiko_runtime.dart` (bagian `cloudBackends`).

**Prasyarat (salah satu):**

- Browserbase: `BROWSERBASE_API_KEY` **dan** `BROWSERBASE_PROJECT_ID`
- Browser Use: `BROWSER_USE_API_KEY`

Tanpa env tersebut tool `cloud_browser` **tidak terdaftar** di registry
(perilaku fail-closed, bukan error saat startup).

**Cara uji manual:**

```bash
export BROWSERBASE_API_KEY=... BROWSERBASE_PROJECT_ID=...
# atau: export BROWSER_USE_API_KEY=...
```

Lalu di sesi chat:

```text
> pakai cloud_browser action=navigate url=https://example.com
> pakai cloud_browser action=read_text
> pakai cloud_browser action=close
```

**Ekspektasi:** hasil navigasi/teks dari backend cloud; router fallback
ke Chromium lokal hanya bila backend lokal tersedia.

---

## 2. Image Generation — `generate_image` (Implemented, conditional)

Sumber: `packages/agent_tools/lib/src/image_generation.dart`,
`image_providers.dart`, config `packages/tiko_runtime/lib/src/tiko_config.dart`
 bagian `features:`, wiring `tiko_runtime.dart` (`enableImageGeneration`).

**Prasyarat:**

1. `config/agent.yaml`:

   ```yaml
   features:
     image_generation: true
     fal_api_key: "env:FAL_KEY"       # SecretRef, jangan tulis key mentah
     # openai_api_key: "env:OPENAI_API_KEY"  # untuk provider OpenAI Images
   ```

2. Env var yang direferensikan harus ter-set saat agentd/tiko dijalankan:

   ```bash
   export FAL_KEY=...
   ```

Tanpa `image_generation: true` + key valid, tool `generate_image` tidak
terdaftar.

**Cara uji manual:**

```text
> generate_image prompt="kucing astronaut, gaya cat air" model=flux-schnell width=512 height=512
```

**Ekspektasi:** tool mengembalikan URL/lokasi file gambar (direktori
output default `images/`). Model tersedia: `fast-sdxl`, `flux-dev`,
`flux-schnell`, `gpt-image-1.5`, `gpt-image-2`, `nano-banana-pro`,
`ideogram-v3`, `recraft-v4-pro`, `qwen`, `z-image-turbo`, `krea-v2-medium`,
`krea-v2-large` (lihat enum di `image_generation.dart`).

---

## 3. Voice (STT / TTS)

### 3.1 STT (speech-to-text) di Telegram (Implemented, conditional)

Sumber: `packages/agent_gateway/lib/src/stt.dart`,
wiring `apps/agentd/bin/agentd.dart` (bagian Telegram).

**Prasyarat (salah satu):**

- Whisper lokal: `WHISPER_BIN=/path/ke/whisper`
- API OpenAI-compatible: `STT_API_KEY` (+ opsional `STT_API_BASE`,
  default `https://api.openai.com/v1`)

Juga wajib: `TG_TOKEN` + `TG_ALLOW` (Telegram gateway standar).

**Cara uji manual:**

```bash
export TG_TOKEN=... TG_ALLOW=<user_id>
export STT_API_KEY=...            # atau WHISPER_BIN=...
cd apps/agentd && dart run bin/agentd.dart
```

Kirim **voice note** dari Telegram ke bot.

**Ekspektasi:** audio ditranskrip (whisper binary atau API), teks
diproses sebagai pesan user normal, balasan muncul di Telegram.

### 3.2 TTS (text-to-speech) (Implemented — library; wiring surface terbatas)

Sumber: `packages/agent_gateway/lib/src/tts.dart`, `tts_providers.dart`
(`TtsProviderFactory`), `voice_loop.dart`, `discord_voice.dart`.

**Status jujur:** provider TTS (OpenAI TTS, xAI, ElevenLabs, MiniMax,
custom command) dan `VoiceLoop`/`DiscordVoiceLoop` tersedia sebagai library
teruji, tetapi **belum ada wiring otomatis** di agentd yang mengubah setiap
balasan chat menjadi audio. Untuk memakainya hari ini, gunakan pemakaian
programmatic:

```dart
final tts = const TtsProviderFactory().create(
  'openai-tts',                 // atau 'xai' | 'elevenlabs' | 'minimax'
  apiKey: apiKey,
  defaultVoice: 'alloy',
);
final service = TtsService(tts);
final audio = await service.speak('Halo dari Tiko'); // List<int> bytes
```

Untuk Discord voice (join VC + play/loop):

- Env gateway Discord: `DISCORD_BOT_TOKEN`, `DISCORD_ALLOW`,
  opsional `DISCORD_APP_ID` (slash command; `DISCORD_SLASH=0` untuk
  menonaktifkan registrasi).
- `DiscordVoiceClient`/`DiscordVoiceLoop` menangani voice gateway + UDP
  (lihat `discord_voice.dart`); uji dengan bot yang di-invite ke guild
  dengan izin Connect/Speak.

**Ekspektasi:** bytes audio PCM/opus sesuai provider; pada Discord,
bot bergabung ke voice channel dan berbicara via `DiscordVoiceLoop`.

---

## 4. Checklist cepat

| Jalur | Env/config minimum | Tool | Status |
|---|---|---|---|
| Browser lokal | `TIKO_CHROME_PATH` (atau Chrome terpasang) | `cdp_browser` | Implemented, conditional |
| Cloud browser | `BROWSERBASE_API_KEY`+`BROWSERBASE_PROJECT_ID` atau `BROWSER_USE_API_KEY` | `cloud_browser` | Implemented, conditional |
| Image gen | `features.image_generation: true` + `FAL_KEY` | `generate_image` | Implemented, conditional |
| STT Telegram | `WHISPER_BIN` atau `STT_API_KEY` | (gateway) | Implemented, conditional |
| TTS | API key provider; pemakaian programmatic | (library) | Implemented (library), wiring surface terbatas |

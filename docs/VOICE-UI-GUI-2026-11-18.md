# Voice UI (dikte + balasan suara) — 18 November 2026

Status: **Implemented** — suara end-to-end di sisi klien (Flutter + web), tanpa
endpoint API baru: STT memakai pengenalan suara perangkat/browser dan TTS
memakai mesin sintesis suara perangkat/browser.

## Ruang lingkup

- **Dikte (STT → input chat):** tombol mic pada composer; transcript
  sanggup disunting sebelum dikirim; partial result tampil live.
- **Balasan suara (TTS):**
  - Flutter: tombol "Dengarkan" di bawah setiap pesan assistant + setting
    "Balasan suara" yang otomatis membacakan balasan akhir tiap turn.
  - Web: toggle "Suara" pada heading chat yang otomatis membacakan balasan
    akhir; TTS dipicu segera setelah turn streaming selesai.
- Pesan yang tidak layak dibacakan otomatis: placeholder (`…`, `Menulis…`,
  `(selesai)`) dan pesan error (`Gagal: …`).

## Flutter (`apps/agent_flutter`)

- Dependencies baru: `speech_to_text: ^7.3.0` (STT Android/iOS/desktop/web,
  bridge Web Speech API) dan `flutter_tts: ^4.2.5` (TTS lintas platform,
  locale `id-ID`).
- File baru `lib/ui/voice_service.dart`:
  - interface `VoiceEngine` + `PlatformVoiceEngine` (speech_to_text +
    flutter_tts) agar seluruh widget dapat diuji dengan engine fake tanpa
    platform channel di `flutter test`;
  - `VoiceService` (ChangeNotifier): state `listening`/`speaking`/`partial`,
    `toggleListening(onFinal:)`, `speak`, `stopSpeaking`, dan helper statis
    `speakableReply(messages)`.
- `_Composer`: tombol mic (`btn-voice-mic`) berstatus pressed/berwarna saat
  mendengarkan; hasil final STT mengganti isi text field (masih dapat
  disunting); hint berganti "Mendengarkan…" dan partial tampil sebagai
  helper text.
- `_ChatPage`: tombol "Dengarkan" per pesan assistant (`btn-speak-msg-N`,
  ikon berubah stop saat sedang berbicara); wrapper `_onSend` membacakan
  balasan akhir bila setting aktif.
- `AppSettings.voiceReply` (default `false`, key `ui.voiceReply`) +
  SwitchListTile "Balasan suara (Voice UI)" di Settings.

## Web (`apps/agentd/web`)

- `index.html`: tombol `#btn-voice-mic` pada composer chat dan toggle
  `#btn-voice-reply` pada heading chat.
- `app.js`:
  - dikte via `window.SpeechRecognition || webkitSpeechRecognition`
    (`lang: id-ID`, interim results); browser tanpa Web Speech API diberi
    pesan yang jelas;
  - TTS via `speechSynthesis` + `SpeechSynthesisUtterance` (`lang: id-ID`);
    `finishTurn()` memicu event internal `tiko:turn-finished` yang dibaca
    `maybeSpeakLastAssistant()` (skip placeholder/error);
  - preferensi tersimpan `localStorage` key `agent_ui_voice_reply`
    (non-kredensial, hanya preferensi perangkat).
- `app.css`: state pressed mic (oranye) dan toggle suara (hijau).

## Verifikasi

- `flutter analyze` bersih; `flutter test` 265 lulus (+8: state machine
  listening/speaking/error, `speakableReply`, persist `voiceReply`).
- `node --check`; `node --test` 39 lulus (+2: mic Web Speech API mengisi
  input; toggle Suara menyimpan preferensi + membacakan balasan akhir dengan
  fake `SpeechRecognition`/`speechSynthesis` di VM harness).
- `scripts/web_ui_validate.sh` lulus; `flutter build web --release` sukses.

## Batasan jujur

- Kualitas STT/TTS bergantung pada mesin perangkat/browser (Android/iOS
  perlu izin mikrofon; desktop tergantung dukungan OS; dikte di web butuh
  browser Chromium-based).
- Bukan streaming voice dua arah (tanpa barge-in/hotword); audio tidak
  pernah dikirim ke daemon — berbeda jalur dengan STT/TTS Telegram/Discord
  gateway yang memakai whisper/API provider.
- Flutter desktop tanpa engine STT OS menampilkan pesan error yang jelas,
  bukan gagal diam-diam.

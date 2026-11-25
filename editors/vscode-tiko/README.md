# Tiko Agent — Ekstensi VS Code (`vscode-tiko`)

Ekstensi editor untuk Tiko-Agent: chat panel di dalam VS Code yang
terhubung ke daemon `agentd` via **SSE `/v1/messages`** (Hermes-P5).

> Catatan: folder ini **bukan bagian CI Dart** (`ci.yml` hanya menganalisa
> dan mengetes workspace member `packages/*` + `apps/{agentd,tiko,agent_cli,simpul}`).
> Build ekstensi dilakukan manual dengan Node/npm.

## Fitur

- **Chat streaming token-level** — frame `chat.delta` dirender incremental,
  sama efeknya dengan GUI web/mobile.
- **Status tool live** — frame `chat.toolStart`/`chat.tool` ditampilkan
  sebagai baris `[tool running|done|error]` per tool.
- **Usage token** — frame `chat.usage` (S20-C: `prompt`/`completion`) dicetak.
- **Cancel turn** — command `Tiko Agent: Cancel Turn` menghentikan iterasi
  stream di sisi editor (pembatalan server-side tetap via WS `{type: cancel}`).
- **Kirim seleksi** — `ctrl+alt+s` mengirim kode terseleksi ke input Tiko.

## Persyaratan

- Daemon agentd berjalan (default `http://127.0.0.1:8787`, loopback-only).
- Token API (`authorization: Bearer ...`) bila daemon diset mewajibkan auth.

## Build manual

```bash
cd editors/vscode-tiko
npm install
npx tsc -p ./
```

Lalu package bila mau VSIX (`vsce package`) atau jalankan langsung via
VS Code "Run Extension" dari folder ini. Ekstensi sedang kerja (S20-D):
kontribusi berikutnya adalah workspace context aktif (@file) dan deteksi
otomatis port agentd.

## Konfigurasi

| Setting                | Default                 | Keterangan                       |
| ---------------------- | ----------------------- | -------------------------------- |
| `tikoAgent.baseUrl`    | `http://127.0.0.1:8787` | Base URL daemon agentd           |
| `tikoAgent.authToken`  | *(kosong)*              | Bearer token API (opsional)      |
| `tikoAgent.sessionKey` | `vscode:default`        | Session key di sisi agentd       |

## Perintah

| Command                  | Keybinding  | Fungsi                          |
| ------------------------ | ----------- | ------------------------------- |
| `tiko-agent.openChat`    | `ctrl+alt+t`| Buka panel chat Tiko            |
| `tiko-agent.cancelTurn`  | —           | Batalkan streaming saat ini     |
| `tiko-agent.sendSelection| `ctrl+alt+s`| Kirim seleksi editor ke input   |

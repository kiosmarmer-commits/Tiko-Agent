# 03-TOOLS-MCP-SKILLS

- **ID dokumen:** AGD-03
- **Bergantung pada:** AGD-01, AGD-02

## 1. Kontrak tool
Setiap tool (built-in, script, atau MCP) dinormalisasi menjadi `ToolSpec`:
```json
{
  "name": "web_fetch",
  "description": "Ambil halaman web dan ubah jadi teks bersih.",
  "risk": "low",
  "input_schema": {"type":"object","properties":{"url":{"type":"string"}},"required":["url"]},
  "timeout_sec": 30,
  "max_output_chars": 20000
}
```
Level risiko (`risk`): `low` (baca saja), `medium` (tulis di workspace), `high` (shell, jaringan keluar
dengan data, hapus), `critical` (di luar workspace, kredensial).

## 2. Matriks izin
| Risiko | Mode `auto` | Mode `ask` (default) | Mode `deny` |
|---|---|---|---|
| low | jalan | jalan | tolak |
| medium | jalan | konfirmasi user | tolak |
| high | **tidak boleh** | konfirmasi user + tampilkan perintah penuh | tolak |
| critical | tidak boleh | konfirmasi dua langkah | tolak |
Konfirmasi dikirim lewat kanal yang sama (Telegram inline button / prompt CLI). Batas waktu konfirmasi 120 detik → tolak.

## 3. Tool bawaan (built-in)
| Tool | Risiko | Catatan |
|---|---|---|
| `read_file`, `list_dir` | low | Terbatas pada workspace |
| `write_file`, `patch_file` | medium | Backup otomatis sebelum timpa |
| `shell` | high | Allowlist perintah + timeout + batas output; tanpa pipe ke jaringan |
| `web_search` | low | SearXNG (lihat AGD-04) |
| `web_fetch` | low | Proteksi SSRF (blok IP privat) |
| `http_request` | high | Hanya domain allowlist |
| `memory_search`, `memory_add` | low | Lihat AGD-04 |
| `schedule_job` | medium | Lihat AGD-05 |
| `datetime`, `calc` | low | Tanpa efek samping |
| `spawn_subagent` | medium | Batas kedalaman 1–2, anggaran token sendiri |

## 4. Script tools (custom)
Struktur folder:
```
tools/<nama_tool>/
  tool.json     # ToolSpec + runtime: {"command":["python3","run.py"]}
  run.py        # baca JSON dari stdin, tulis JSON ke stdout
```
Aturan runner (`Process.start`):
1. Argumen lewat **stdin JSON**, bukan string shell (cegah injeksi).
2. `workingDirectory` = folder tool; environment dibersihkan, hanya variabel yang dideklarasikan.
3. Timeout (default 30 dtk) → `kill` seluruh proses; batasi stdout (mis. 1 MB) dan stderr.
4. Hasil harus JSON valid; jika gagal, kembalikan error terstruktur ke model.
5. Hash (SHA-256) `tool.json` + skrip disimpan; perubahan memicu konfirmasi ulang.

## 5. MCP (Model Context Protocol)

Implementasi runtime saat ini memakai transport **stdio JSONL** dan dua jalur negosiasi:
- Probe `server/discover` untuk server stateless MCP **2026-07-28**. Metadata versi, identitas client, dan kemampuan dikirim pada setiap request.
- Jika probe mendapatkan error method-not-found atau timeout legacy, klien memakai `initialize` versi **2025-11-25** lalu `notifications/initialized`.
- Request keluar selalu JSONL satu pesan per baris. Parser juga menerima respons `Content-Length` untuk kompatibilitas dengan server non-standar lama.
- Child process MCP baru diluncurkan setelah daemon memegang instance lock; setiap server memakai workspace privat, allowlist eksplisit, risiko minimal `medium`, dan secret hanya melalui `env:NAMA`.
- OS sandbox tidak tersedia berarti MCP dinonaktifkan. Sandbox saat ini menonaktifkan akses jaringan; server MCP yang membutuhkan koneksi internet belum dapat dipakai melalui jalur ini.

**Status pengujian:** mock modern dan legacy diuji melalui fixture lokal. Interoperabilitas dengan server vendor nyata tetap menjadi release gate sebelum rilis produksi; transport Streamable HTTP belum diimplementasikan.

**Strategi:**
1. Pertahankan interface `McpTransport` agar transport stdio dan HTTP bisa ditambahkan tanpa mengubah AgentLoop.
2. Uji `tools/list` dan `tools/call` pada server 2025-11-25 dan 2026-07-28 dari vendor berbeda.
3. Perlakukan seluruh keluaran MCP sebagai data tidak tepercaya; provenance/taint tidak boleh menaikkan privilege.
4. Setiap server MCP harus punya ID unik, allowlist nama tool non-kosong, dan klasifikasi risiko eksplisit.

## 6. Skills (prosedural)
Hermes menyatakan kompatibilitas dengan standar terbuka `agentskills.io` (✅ dari README; detail format
⚠️ belum diverifikasi). Rancangan kita:
```
skills/<slug>/SKILL.md
---
name: ringkas-berita-harian
description: Cara meringkas berita pagi dari SearXNG, kirim ke Telegram
triggers: ["berita", "ringkasan pagi"]
tools: [web_search, web_fetch]
version: 3
status: approved   # draft | trial | approved | retired
---
## Langkah
1. ...
## Catatan/Kegagalan umum
- ...
```
Siklus hidup: `draft` (dibuat agent) → `trial` (dipakai dengan pengawasan, dicatat hasilnya) →
`approved` (lulus ambang sukses atau disetujui user) → `retired`. Detail otomatisasi di AGD-06.
Pemuatan: hanya deskripsi skill masuk prompt; isi penuh dimuat saat relevan (hemat konteks).

## 7. Sandbox
| Lingkungan | Opsi | Catatan |
|---|---|---|
| Linux/VPS | Docker/Podman, `bubblewrap` | Jaringan dimatikan secara default untuk eksekusi kode |
| Termux | `proot` (isolasi terbatas) | Bukan sandbox keamanan sejati; batasi dengan allowlist |
| Flutter Android | Tanpa shell | Hanya tool aman |

## 8. Task
| ID | Task | Kriteria selesai |
|---|---|---|
| TASK-03-01 | Registry + validasi JSON Schema argumen | Tes argumen salah ditolak |
| TASK-03-02 | PermissionGate + konfirmasi lewat CLI | Tes matriks izin |
| TASK-03-03 | Script tool runner (stdin JSON, timeout, batas output) | Tes timeout dan output besar |
| TASK-03-04 | Klien MCP stdio (`dart_mcp`) + tes kompatibilitas spec | Dua server nyata terhubung |
| TASK-03-05 | Loader skill + frontmatter parser | Skill dimuat sesuai trigger |

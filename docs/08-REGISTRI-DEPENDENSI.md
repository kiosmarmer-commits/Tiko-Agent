# 08-REGISTRI-DEPENDENSI

- **ID dokumen:** AGD-08
- **Tanggal verifikasi:** 2026-11-04
- **Metode:** pencarian web (pub.dev, ecosyste.ms, PyPI, GitHub, dokumen LiteLLM, blog teknis). Tanggal rilis dari
  agregator bisa tertinggal; gunakan skrip bagian 4 untuk konfirmasi langsung.

## 1. Kriteria "aktif dan terbaru" (K)
| ID | Kriteria | Ambang |
|---|---|---|
| K-1 | Rilis terakhir | ≤ 12 bulan (pustaka matang milik tim resmi boleh lebih lama, ditandai) |
| K-2 | Status | Tidak `discontinued` / tidak diarsipkan |
| K-3 | Kompatibilitas | Mendukung Dart 3.x null-safety; lolos analisis pub.dev |
| K-4 | Lisensi | Jelas dan sesuai (perhatikan AGPL/MPL) |
| K-5 | Penerbit | Terverifikasi lebih diutamakan |
| K-6 | Kematangan | Pra-v1 hanya boleh di balik interface yang bisa diganti |

## 2. Paket Dart
| ID | Paket | Peran | Versi terverifikasi | Aktivitas | Lisensi | Status | Sumber |
|---|---|---|---|---|---|---|---|
| DEP-01 | `openai_dart` | LLM OpenAI/compat | 11.0.1 | Aktif (monorepo langchain_dart) | MIT* | ✅ | pub.dev skor `dart_mcp_core` |
| DEP-02 | `ollama_dart` | Ollama native | 4.0.0 | Aktif | MIT* | ✅ | idem |
| DEP-03 | `anthropic_sdk_dart` | Claude API | 9.0.0 | Aktif | MIT* | ✅ | idem |
| DEP-04 | `googleai_dart` | Gemini API | 13.0.0 | Aktif | MIT* | ✅ | idem |
| DEP-05 | `dart_mcp` | MCP klien/server (resmi dart-lang) | 0.4.1 | ±1 bulan sebelum sinkronisasi; 193★ | BSD-3 | ✅ (spec 2026-07-28 ⚠️) | ecosyste.ms |
| DEP-06 | `dart_mcp_core` | Inti MCP + agent engine | 1.5.0 | Baru; ≈850 unduhan | belum dicek | ⚠️ evaluasi saja | pub.dev |
| DEP-07 | `drift` | ORM SQLite | 2.32.0 | ±23 hari; 3.024★; 162 kontributor | MIT | ✅ | ecosyste.ms |
| DEP-08 | `televerse` | Telegram | 3.3.0 | ±1 hari; Bot API 9.5; 96★ | BSD-3 | ✅ | ecosyste.ms |
| DEP-09 | `nyxx` | Discord | 6.8.1 | ±3 bulan; 333★ | Apache-2.0 | ✅ | ecosyste.ms |
| DEP-10 | `enough_mail` | IMAP/SMTP | 2.1.7 | ±6 bulan (jeda 2 th sebelumnya) | MPL-2.0 | ✅ ritme lambat | ecosyste.ms |
| DEP-11 | `dart_frog` | Server HTTP/WS | 1.2.6 (cli 1.2.13) | ±4 bulan; 2.039★ | MIT | ✅ | ecosyste.ms |
| DEP-12 | `shelf` | Server HTTP (dart-lang) | 1.4.2 (Jun 2024) | Matang, jarang dirilis | BSD-3 | ⚠️ stabil, bukan "baru" | ecosyste.ms |
| DEP-13 | `langchain` (+ `langchain_*`) | Abstraksi LLM | 0.8.x–0.9.0 terlihat | Aktif, tapi tidak dipakai di inti | MIT* | ⚠️ opsional | pub.dev |
| DEP-14 | `tavily_dart` | Pencarian Tavily | 0.1.3 (snapshot lama) | belum dicek | MIT* | ⚠️ | GitHub commit langchain_dart |
| DEP-15 | `floor` | ORM SQLite | 1.5.0 (±2 th) | Tidak aktif | Apache-2.0 | ❌ hindari | ecosyste.ms |
| DEP-16 | `dio`, `http` | HTTP klien | — | — | — | ⚠️ cek | belum diverifikasi |
| DEP-17 | `sqlite3` | Driver SQLite FFI | — | — | — | ⚠️ cek | belum diverifikasi |
| DEP-18 | `cron`, `workmanager`, `flutter_background_service` | Penjadwalan | — | — | — | ⚠️ cek | belum diverifikasi |
| DEP-19 | `riverpod`, `flutter_secure_storage`, `args`, `logging`, `html`, `yaml`, `path`, `uuid` | Pendukung | — | — | — | ⚠️ cek (paket umum, risiko rendah) | belum diverifikasi |
| DEP-20 | `teledart`, `mcp_dart`, `mcp_server_dart` | Alternatif | `mcp_server_dart` 1.2.0 (±7 bln, 17★) | — | MIT | ⚠️ | ecosyste.ms |
| DEP-21 | `timezone` | Database zona IANA + TZDateTime untuk cron scheduler | 0.10.2 (data IANA 2025c) | Stabil | BSD-2 | ✅ (pra-v1, di balik interface Tz — K-6) | pub.dev |
*Lisensi `*` = diasumsikan dari repositori `davidmigloz/langchain_dart`; konfirmasi di pub.dev.

## 3. Proyek non-Dart
| ID | Proyek | Peran | Versi terverifikasi | Aktivitas | Lisensi | Status | Sumber |
|---|---|---|---|---|---|---|---|
| EXT-01 | **Ollama** | Runtime LLM lokal | v0.40.6 (2026-10-16) | Aktif | MIT | ✅ | developersdigest.tech (rujuk GitHub Releases) |
| EXT-02 | **Laya** | Decision model lokal | v0.4.6 (README); rilis PyPI seri 0.3.x–0.4.x | Aktif, rilis sering | Apache-2.0 | ✅ | PyPI, everydev.ai, aiweekly |
| EXT-03 | **Bespoke Nimble** | Decision model via Ollama | — | — | terbuka | ✅ disebut di dokumen LiteLLM; versi ⚠️ | docs.litellm.ai |
| EXT-04 | **Jev** (TypeSafe AI) | Decision model hosted | jev-1.13.0 / jev-latest | Rilis 2026-09-15, early access | Proprietary | ✅ | docs LiteLLM, pinggy, langchain4j |
| EXT-05 | **SearXNG** | Metasearch self-host | rolling, build 2026.10.24 | Aktif | AGPL-3.0 | ✅ | promptquorum.com (rujuk Docker Hub) |
| EXT-06 | **sqlite-vec** | Vektor di SQLite | v0.1.9 (Mar 2026) | Aktif tapi **pra-v1** | MIT/Apache | ⚠️ | npm/RubyGems/FreeBSD |
| EXT-07 | **MCP spec** | Protokol tool | 2026-07-28 | Revisi terbaru | — | ✅ | scalar.com, dev.to |
| EXT-08 | **Hermes Agent** | Referensi desain | rilis aktif (2.770+ commit pada salah satu fork) | Aktif | MIT | ✅ | GitHub README |
| EXT-09 | LocalJev, jeff, SemIf/OpenJev, NanoJev | Alternatif decision | — | Baru (Sep 2026) | MIT (sebagian) | ⚠️ dari blog | pinggy.io, scriptbyai.com |
| EXT-10 | llama.cpp, whisper.cpp, Piper, Vosk, bge-m3, Qdrant | Model/runtime lain | — | — | — | ⚠️ belum diverifikasi | — |

## 4. Skrip verifikasi ulang (jalankan di perangkat dengan internet)
Simpan sebagai `scripts/verify_deps.py`, jalankan `python3 scripts/verify_deps.py`.
```python
import json, sys, urllib.request
from datetime import datetime, timezone

PKGS = ["openai_dart","ollama_dart","anthropic_sdk_dart","googleai_dart","dart_mcp","drift","sqlite3",
        "televerse","nyxx","enough_mail","dart_frog","shelf","dio","http","cron","workmanager",
        "riverpod","flutter_secure_storage","args","logging","html","yaml","path","uuid"]

def get(url):
    with urllib.request.urlopen(url, timeout=20) as r:
        return json.load(r)

now = datetime.now(timezone.utc)
print(f"{'paket':28} {'versi':12} {'umur(hari)':>10}  status")
for p in PKGS:
    try:
        d = get(f"https://pub.dev/api/packages/{p}")
        latest = d["latest"]
        pub = datetime.fromisoformat(latest["published"].replace("Z", "+00:00"))
        age = (now - pub).days
        flag = "DISCONTINUED" if d.get("isDiscontinued") else ("PERIKSA(>365h)" if age > 365 else "ok")
        print(f"{p:28} {latest['version']:12} {age:>10}  {flag}")
    except Exception as e:
        print(f"{p:28} {'-':12} {'-':>10}  ERROR {e}")
```
Setelah itu: `dart pub add <paket>` (otomatis memilih versi kompatibel terbaru), lalu `dart pub outdated`.

## 5. Kebijakan pembaruan
1. Verifikasi ulang bulanan (TASK-08-02); catat hasil di `docs/dependency-log.md`.
2. Pin versi lewat `pubspec.lock`; naikkan versi mayor hanya dengan tes golden (AGD-06 §3).
3. Hindari rilis < 14 hari untuk lingkungan produksi (risiko rantai pasok; AGD-07 C-11).
4. Paket ⚠️ **tidak boleh** menjadi ketergantungan inti sebelum lolos K-1..K-6.

## 6. Task
| ID | Task | Kriteria selesai |
|---|---|---|
| TASK-08-01 | Jalankan skrip verifikasi dan tempel hasil ke `dependency-log.md` | Semua baris ⚠️ pada bagian 2 terisi |
| TASK-08-02 | Jadwalkan verifikasi bulanan (job scheduler agent sendiri) | Laporan terkirim ke Telegram |
| TASK-08-03 | Konfirmasi lisensi `langchain_dart` family di pub.dev | Kolom lisensi terisi |

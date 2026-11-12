# Tiko / Agent Dart — Full Repair Report

- **Tanggal:** 7 November 2026
- **Basis source:** `agent_dart_tiko_p1_partial.zip`
- **Cakupan:** hardening dan penyambungan runtime setelah tranche P0/P1 parsial, termasuk regression tests dan pipeline CI
- **Status patch:** diterapkan pada source tree ini
- **Status release:** **belum build-verified** karena Dart SDK dan Flutter SDK tidak tersedia pada lingkungan pengerjaan

## 1. Ringkasan

Perbaikan dilakukan pada core agent, runtime, memory store, scheduler, keamanan tool, MCP, skill registry, CLI, daemon, API, dan validasi Flutter/CI. Perubahan basis kode dibandingkan arsip P1 parsial mencakup 54 file yang diubah dan 7 file baru (6 file regression test dan 1 script validasi Flutter), di luar laporan ini.

Perbaikan paling penting:

1. Metadata provenance/trust memory dipertahankan di SQLite dan JSON; pencarian memory hanya mengembalikan fakta aktif dari sumber tepercaya.
2. Offline queue memakai claim/lease/ack/retry dengan token lease unik, sehingga worker lama tidak dapat mengakui pekerjaan yang sudah kedaluwarsa.
3. Shell, MCP, dan script kustom tidak memiliki fallback untuk mengeksekusi proses langsung di host saat OS sandbox tidak tersedia.
4. MCP mendukung negosiasi stateless modern dan handshake legacy, dengan allowlist eksplisit dan proses yang dikelola lifecycle daemon.
5. Path workspace memeriksa canonical path dan symlink, termasuk kasus target belum ada di bawah symlink.
6. Approval menghasilkan capability sekali-pakai yang terikat ke sesi, tool, operasi, workspace, ukuran, dan fingerprint argumen yang disetujui.
7. Skill impor tetap draft; feedback/metadata file tidak bisa mengaktifkan skill tanpa scan, evaluasi runtime nyata, dan persetujuan eksplisit.
8. Admin API sekarang membaca/menghapus memory melalui `SafeMemoryStore` dengan benar, termasuk backend JSON fallback.

## 2. Detail perbaikan

### 2.1 Memory dan provenance

- `Fact`/`MemoryHit` membawa provenance, confidence, TTL metadata, dan state.
- Skema SQLite dinaikkan ke versi 5 dengan migrasi kolom yang kompatibel terhadap database lama.
- Backend JSON menyimpan metadata yang sama dan memuat catatan lawas sebagai provenance `unknown`.
- `SafeMemoryStore` meredaksi secret, menetralkan konten tidak tepercaya, menurunkan trust untuk catatan agent/tool, dan hanya menampilkan fakta aktif dari user atau konfigurasi tepercaya pada retrieval biasa.
- `memory_add` menyimpan catatan buatan model sebagai kandidat `pending`, bukan fakta user.
- Memori tepercaya baru diambil dari pesan user yang secara eksplisit meminta untuk mengingat/menyimpan atau menyatakan preferensi/identitas dengan pola yang dibatasi.
- Hasil `memory_search` dibungkus sebagai untrusted data dan string envelope yang dapat memalsukan penutup dinetralkan.
- Ditambahkan penghapusan fakta backend JSON; admin runtime membuka wrapper `SafeMemoryStore` sebelum operasi list/delete.
- Tes baru memeriksa provenance, status pending, explicit memory capture, dan operasi administrasi.

**Batas:** `ttl_days` sekarang disimpan sebagai metadata; penghapusan otomatis saat masa TTL habis belum diimplementasikan. Penghapusan fakta JSON juga belum membersihkan embedding dari seluruh implementasi vector index; hasil vector yatim tetap difilter sebagai `unknown/pending` oleh safety wrapper.

### 2.2 Offline queue

- Queue menggunakan status `pending`, `in_flight`, dan `acked`.
- Worker harus melakukan `claim()` dahulu; setiap claim menghasilkan token lease unik.
- `ack()` dan `retry()` memvalidasi ID, token, status, serta waktu lease. Worker yang terlambat tidak bisa menyelesaikan pekerjaan yang sudah kedaluwarsa.
- Item lama tanpa status/token dimigrasikan sebagai pending.
- File queue, jumlah item, ukuran, dan isi pesan dibatasi; file corrupt dipisahkan ke file karantina.
- CLI `tiko offline drain` sekarang memproses item dengan claim → chat → ack, atau retry ketika gagal.
- Regression tests mencakup claim, retry, restart, lease expiry, serta worker stale.

**Batas:** pola ini memberikan delivery *at-least-once*. Jika proses mati setelah sebuah tool melakukan side effect eksternal tetapi sebelum ack tersimpan, job dapat diproses ulang. Tool yang berdampak eksternal tetap perlu idempotency key atau deduplikasi pada sisi tujuan.

### 2.3 Scheduler dan cron

- Parser cron 5-field memvalidasi rentang dan step dengan ketat.
- Semantik day-of-month/day-of-week mengikuti OR ketika keduanya dibatasi.
- Zona waktu disimpan pada job dan dipakai saat menghitung jadwal berikutnya.
- Job yang diklaim dipersistenkan sebelum dieksekusi; run pending diputar ulang setelah restart.
- Kegagalan melepaskan claim agar run yang sama bisa dicoba kembali; shutdown menunggu tick aktif dengan batas waktu.
- Runtime sekarang memiliki satu lifecycle scheduler; hasil job diarahkan hanya ke gateway dengan channel yang sama. Bila tidak ada gateway yang cocok, hasil tetap di sesi/log, bukan dikirim ke gateway lain.

**Batas:** zona waktu yang didukung baru UTC dan fixed offset Indonesia (`Asia/Jakarta`, `Asia/Pontianak`, `Asia/Makassar`, `Asia/Jayapura`, serta `Etc/UTC`). IANA timezone umum dan DST belum didukung. Kebijakan catch-up memproses missed run satu per tick, bukan melakukan burst tanpa batas.

### 2.4 Provider routing dan AgentLoop

- Router memiliki health tracking, circuit breaker/fallback chain, dan event fallback yang bisa diamati.
- Error provider yang muncul sebelum event `Done` tetap dianggap kegagalan.
- Provider error detail tidak diteruskan mentah ke transcript user.
- AgentLoop mencatat nama tool yang benar-benar dijalankan untuk assertion golden, bukan hanya nama tool yang disebut model.
- Taint sesi diperluas untuk hasil file/list/shell/patch selain hasil web/MCP/script.
- Batas iterasi/tool budget tetap menghentikan proses ketika terlampaui.

### 2.5 Skill safety dan golden evaluation

- Import skill mengabaikan klaim `status: approved` di frontmatter dan memaksa status `draft`.
- Pemakaian dan feedback tidak lagi mempromosikan draft/trial secara otomatis.
- Fingerprint evaluasi mencakup metadata dan isi skill; perubahan atau rollback membatalkan hasil evaluasi sebelumnya.
- Golden YAML menggunakan parser YAML sungguhan dan memvalidasi schema, ID duplikat, ukuran, weight, regex, serta daftar tool.
- Golden harness memeriksa tool yang benar-benar dieksekusi.
- Promosi diblokir bila evaluator AgentLoop/sandbox yang nyata belum dikonfigurasi.

**Batas:** integrasi evaluator golden end-to-end ke `tiko skills evaluate/approve` belum selesai. Dengan konfigurasi saat ini, skill tidak dapat naik status otomatis/produksi; fail-closed ini disengaja agar file lokal atau feedback tidak dapat memberi privilege.

### 2.6 Filesystem, shell, dan script runner

- Path safety melakukan canonicalization terhadap root dan nearest existing ancestor; traversal, symlink escape, broken symlink, special file, serta sibling path dengan prefix mirip ditolak.
- `PatchFileTool` memakai helper canonical yang sama, bukan pemeriksaan prefix string.
- List directory, file content, patch, backup, dan argumen tool memiliki batas ukuran/jumlah.
- Penulisan file memeriksa ulang canonical path setelah direktori dibuat untuk mengurangi race symlink.
- Sandbox tidak menjalankan proses host secara langsung ketika `SandboxKind.none`.
- Bubblewrap diuji dengan namespace yang memang dipakai runtime; Docker menggunakan image lokal (`--pull=never`), network none, read-only root, cap drop, no-new-privileges, pids/memory/cpu limit, dan `/tmp` noexec.
- Argumen/environment dibatasi; env sistem dan variabel kendali Docker/loader/Python tidak dapat ditimpa konfigurasi tool.
- Script runner membuat workspace privat per tool, menyalin hanya file reguler yang lolos batas, dan mengecualikan `.env`, `.git`, cache, build, dan metadata internal.
- Symlink/special file pada script bundle ditolak; temporary workspace dibersihkan ketika runtime/CLI ditutup dan bila proses load gagal.
- `agent_cli` ditandai sebagai prototipe legacy dan diarahkan ke command `tiko`.

**Batas:** pemeriksaan ulang path mengurangi, tetapi tidak menghapus seluruh kemungkinan TOCTOU race pada filesystem. Perlindungan penuh membutuhkan primitive OS seperti `openat`/directory file descriptor dan sandbox yang diuji pada masing-masing host.

### 2.7 MCP

- Client stdio mendukung stateless discovery modern `server/discover` dengan metadata versi pada request, dan fallback ke legacy `initialize` ketika server lama terdeteksi.
- Outbound stdio memakai JSONL; parser response juga menerima framing Content-Length untuk kompatibilitas.
- Fixture Python menyediakan mode modern dan legacy; smoke manual memvalidasi discover/initialize, tools/list, dan tools/call.
- Loader membatasi jumlah server, menolak ID duplikat, mewajibkan allowlist non-kosong, membatasi risiko minimal `medium`, dan memberi workspace privat per server.
- Child process MCP hanya dimulai setelah daemon memiliki instance lock dan ditutup saat runtime shutdown.
- Server mati menjadi status error; tidak dianggap sehat otomatis.
- Output MCP dibungkus untrusted dan dibatasi.
- Config MCP typed; raw secret ditolak dan environment secret hanya direferensikan melalui `env:NAMA`.

**Batas:** transport Streamable HTTP belum diimplementasikan. Sandbox saat ini mematikan network namespace/network Docker, sehingga MCP server yang membutuhkan akses Internet/API eksternal tidak dapat berjalan dengan konfigurasi sandbox ini. Interoperabilitas terhadap vendor MCP nyata belum diuji; fixture lokal bukan pengganti tersebut.

### 2.8 Approval dan capability

- Capability id acak, single-use, berumur pendek, terikat session dan tool.
- Fingerprint argumen dibuat secara kanonik (key map terurut) dan mengabaikan hanya `_capability_id` top-level yang ditempel setelah approval.
- Perubahan argumen, scope operasi, workspace, ukuran payload, sesi, tool, expiry, atau replay menyebabkan penolakan.
- Tool tak dikenal menggunakan risiko tinggi; risiko deklarasi tool tidak dapat menurunkan risiko bawaan.
- Tool dinamis MCP/script memerlukan capability.

### 2.9 CI dan scripts

- Workflow Dart mencakup pub get, strict analyze, seluruh package/app tests, CLI deterministic/setup/config smoke, compile executable, dan daemon HTTP lifecycle smoke.
- Flutter validation dipisah menjadi `scripts/flutter_validate.sh`: pub get, analyze, seluruh tests, dan web release build.
- `scripts/validate.sh` memanggil Flutter validation sebagai release gate; tidak memakai `continue-on-error` atau `|| true` untuk menutupi kegagalan.
- Bash/Python syntax validation disatukan di pipeline.
- Build Flutter tidak menyisipkan API token melalui `--dart-define`; token API tetap dikelola runtime/secure storage.

## 3. Berkas utama yang disentuh

- `packages/agent_core`: `agent_loop.dart`, `context_builder.dart`, `models.dart`, `router.dart`, `golden.dart`, `skill_gate.dart`, `skill_scanner.dart`, `skills.dart`.
- `packages/agent_memory`: SQLite schema/migration, JSON persistence, in-memory store, safe wrapper, store tests.
- `packages/agent_scheduler`: cron, job store, scheduler, schedule tool, scheduler tests.
- `packages/agent_security`: permission gate, capability gate, panic/kill switch, sanitizer, tests.
- `packages/agent_tools`: built-in file tools, path safety, patch, sandbox, script runner, MCP registry/client, memory tools, tests.
- `packages/tiko_runtime`: config, capability vault, offline queue, runtime composition and lifecycle, tests.
- `apps/tiko`, `apps/agentd`, `apps/agent_cli`, `.github/workflows/ci.yml`, `scripts/*.sh`, `tools/mock_mcp_server/server.py`, `docs/03-TOOLS-MCP-SKILLS.md`.

## 4. Verifikasi yang benar-benar dijalankan di lingkungan ini

| Pemeriksaan | Hasil |
|---|---:|
| `bash -n` seluruh script shell | **PASS — 7/7** |
| `python3 -m compileall -q scripts tools/mock_mcp_server` | **PASS** |
| Parsing seluruh YAML/YML proyek | **PASS — 23/23** |
| Parsing JSON proyek | **PASS — 2/2** |
| MCP mock stateless modern (`server/discover`, list, call) | **PASS** |
| MCP mock legacy (`initialize`, list, call) | **PASS** |
| Pencarian pemanggilan `dev-token` dan named argument `onConfirm:` lama | **PASS — tidak ditemukan** |
| Dart SDK tersedia | **NO** |
| Flutter SDK tersedia | **NO** |
| `dart pub get`, `dart analyze`, `dart test`, compile exe | **BELUM DIJALANKAN** |
| `flutter analyze`, `flutter test`, web release build | **BELUM DIJALANKAN** |
| Live daemon/API, Android/Termux device, real MCP/provider integration | **BELUM DIJALANKAN** |

Penting: pemeriksaan statis non-Dart di atas tidak membuktikan kode Dart sudah bebas compile error. Saya tidak memberi status build/test PASS untuk Dart atau Flutter.

## 5. Verifikasi wajib di mesin dengan Dart/Flutter

Dari root source tree:

```bash
dart --version
flutter --version
dart pub get
bash scripts/validate.sh
```

Pipeline di atas menjalankan strict analyzer, tes semua package/app, kalkulator `6`, setup/config mock dan Ollama, chat mock, compile entrypoint, daemon lifecycle smoke, lalu validasi Flutter.

Untuk memisahkan validasi Flutter:

```bash
bash scripts/flutter_validate.sh
```

Jika analyzer/test gagal, perbaiki error pertama yang relevan lalu jalankan ulang pipeline penuh. Jangan melewati gate dengan `|| true`.

## 6. Pekerjaan yang masih terbuka sebelum rilis produksi

1. Jalankan semua analyzer, unit/integration tests, AOT compile, Flutter tests, dan Web build pada Dart 3.13.4 / Flutter 3.47.5; selesaikan error yang hanya dapat ditemukan compiler/runtime.
2. Lengkapi subagent runner beserta depth/token/time budgets, cancellation, dan permission inheritance sebelum mendaftarkannya di runtime.
3. Hubungkan golden evaluator yang menjalankan AgentLoop nyata di sandbox terisolasi ke command promotion skill.
4. Tambahkan expiry enforcement untuk TTL memory dan vector index deletion API.
5. Tambahkan dukungan IANA timezone/DST dan tes missed-run untuk seluruh kebijakan scheduler.
6. Implementasikan serta uji MCP Streamable HTTP dengan autentikasi, allowlist, timeout, dan lifecycle yang sama ketatnya; evaluasi kebijakan network sandbox yang terisolasi.
7. Pertimbangkan SQLite transaction/file lock untuk approval/offline queue bila beberapa proses boleh menulis store secara bersamaan.
8. Tambahkan integration tests untuk restart/crash-recovery, idempotency side effects, migrasi data produksi, serta pengujian Android/Termux dan Linux/VPS.
9. Lakukan threat-model independen dan pengujian filesystem race/OS sandbox pada target rilis nyata.

## 7. Catatan cakupan spesifikasi

Arsip source yang menjadi basis berisi dokumen arsitektur AGD dan laporan P0/P1, tetapi file mandiri `10-PRD-PASITIKO-TIKO.md` tidak tersedia di snapshot yang diperiksa. Karena itu laporan ini mengaudit implementasi source dan backlog yang tercatat pada laporan sebelumnya; ini bukan klaim bahwa semua acceptance criteria PRD asli telah dibuktikan.

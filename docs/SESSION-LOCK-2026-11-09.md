# Perbaikan: Kunci File Lintas Proses untuk Session Store

- Tanggal: 2026-11-09
- Repo: `kiosmarmer-commits/Tiko-Agent` (branch `main`)
- Bloker: "cross-process session-store locking" dari `TIKO-REPAIR-STATUS-2026-11-07.md`
- Jejak audit: feat `888fc41` ("feat(memory): kunci file lintas proses untuk session store (refresh-under-lock, no lost updates)")

## Masalah

`FileSessionStore` memuat `sessions.json` sekali per proses (`_ensureLoaded`) lalu menulis snapshot in-memory penuh setiap kali berubah (`_persist` menimpa seluruh file). `_writeChain` hanya membuat antrean tulis dalam satu proses. Akibatnya dua proses yang membuka store yang sama — misalnya daemon `agentd` dan CLI, atau dua instance runtime — saling menimpa: proses yang menulis terakhir menimpa seluruh state yang pernah ditulis proses lain (lost update). Dalam satu proses pun, dua turn konkuren bisa memutas map cache sebelum persist selesai.

## Desain

Tulis ulang `packages/agent_memory/lib/src/file_session_store.dart`:

1. **Rantai in-process** — `_transaction(action)`: operasi publik ditandatangani ke rantai `Future`; operasi berikutnya menunggu operasi sebelumnya selesai (termasuk yang gagal, tanpa merusak rantai).
2. **Kunci lintas proses** — `_withFileLock(action)`: membuka `sessions.json.lock`, mengambil `FileLock.exclusive` pada `RandomAccessFile`, menjalankan aksi, lalu unlock + close. Lock file bersifat advisory dan dirilis OS secara otomatis bila proses mati, sehingga tidak ada deadlock permanen.
3. **Refresh-under-lock** — `_refreshFromDisk()` mengosongkan cache lalu memuat ulang dari disk. Setiap operasi publik melakukan refresh di bawah kunci sebelum memutas state, jadi proses ini selalu memutas state on-disk terbaru, bukan snapshot basi dari operasi sebelumnya.
4. Semua 5 metode publik (`getOrCreate`, `recent`, `appendTurn`, `list`, `delete`) dibungkus `_transaction(() => _withFileLock(...))` dengan body asli dipertahankan. `_persist` tetap atomik (file tmp + rename, nonce pid) dan kini dipanggil di bawah kunci.

Semantik lama yang dipertahankan: karantina file korup (`sessions.json.corrupt-*`), redaksi secret pada load/persist, cap pesan per sesi, urutan `list()` terbaru-dulu.

## Matriks test

Test `packages/agent_memory/test/file_session_store_test.dart` (5 lama dipertahankan + 2 baru):

| Test | Yang diverifikasi |
| --- | --- |
| history survives restart (lama) | perilaku restart tidak berubah |
| recent respects limit and order (lama) | limit + urutan tetap |
| sessions are isolated and deletable (lama) | isolasi + delete idempoten |
| corrupt file is quarantined (lama) | karantina tetap bekerja |
| message cap per session (lama) | cap pesan tetap |
| concurrent appends (baru) | 5 `appendTurn` paralel via `Future.wait` → 10 pesan & 5 turn tersimpan |
| two instances take turns (baru) | instance kedua tidak menimpa turn instance pertama → 4 pesan & 2 turn |

## Trade-off

- Setiap operasi kini membaca ulang file: I/O bertambah, tetapi `sessions.json` kecil dan kebenaran lebih penting daripada latensi.
- Kunci bersifat advisory: hanya proses yang lewat `FileSessionStore` yang dijaga; penulisan manual ke file tidak dilock.
- Pada filesystem jaringan, `flock` tidak selalu andal — store ini memang ditujukan untuk disk lokal.

## Status

Selesai; menunggu konfirmasi CI hijau di HEAD setelah seluruh rangkaian commit sesi ini.

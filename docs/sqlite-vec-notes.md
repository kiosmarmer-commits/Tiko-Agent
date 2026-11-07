# TASK-04-04 sqlite-vec

Default production path tetap `BruteForceVectorIndex` (DEC-05).

Uji `sqlite-vec` di target:

```bash
# Linux
# build/load extension sesuai docs asg017/sqlite-vec

# Termux — sering gagal load .so dinamis; andalkan brute-force
# Android/iOS — iOS melarang dynamic load; compile static bila dipakai
```

Kriteria: bila extension gagal dimuat → fallback otomatis ke brute-force tanpa crash.

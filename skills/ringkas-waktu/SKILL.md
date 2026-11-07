---
name: ringkas-waktu
description: Cara menjawab pertanyaan waktu/tanggal dengan tool datetime
triggers: ["waktu", "tanggal", "jam berapa"]
tools: [datetime]
version: 1
status: approved
---

## Langkah
1. Panggil tool `datetime` tanpa argumen.
2. Sampaikan hasil ISO-8601 ke pengguna dalam bahasa Indonesia singkat.

## Kegagalan umum
- Model menjawab waktu dari pengetahuan parametrics tanpa tool → selalu pakai tool.

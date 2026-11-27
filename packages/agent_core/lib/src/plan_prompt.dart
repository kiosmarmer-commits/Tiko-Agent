// Hermes parity: `agent/plan_prompt.py` — `/plan` mode rencana.
//
// Prompt plan mode: menyimpan rencana implementasi markdown, tanpa
// eksekusi. First-class built-in tanpa engine dan tanpa jejak model-tool:
// setiap permukaan mem-feed [buildPlanPrompt] ke agent sebagai turn biasa
// (seperti `/learn`), sehingga system prompt dan riwayat tetap tersentuh
// minimal (aman prompt-cache).
//
// Deviasi sadar dari Hermes:
// - Hermes menyimpan rencana di `.hermes/plans/`; Tiko memakai `plans/`
//   di dalam workspace — `.tiko/` ditolak file-safety fase-12 untuk tulisan
//   agent, dan `plans/` relatif workspace tetap membuat rencana hidup
//   bersama proyek.
// - Teks aturan dan craft diterjemahkan ke Bahasa Indonesia (konvensi repo);
//   struktur dan aturan isinya setara Hermes.
library;

/// Marker header prompt plan mode (Hermes `[/plan — plan mode]`).
const String planModeMarker = '[/plan — plan mode]';

/// Direktori rencana di dalam workspace (lihat deviasi di header library).
const String planDirName = 'plans';

/// Ground rules + craft penulisan (writing-craft diadaptasi dari
/// obra/superpowers ala Hermes).
const String _planModeRules = '''
Untuk giliran ini, Anda berada dalam PLAN MODE — merencanakan saja.

- Jangan mengimplementasi kode.
- Jangan mengedit file proyek selain file rencana markdown itu sendiri.
- Jangan menjalankan perintah terminal yang bersifat mengubah, commit, push,
  atau melakukan aksi eksternal.
- Anda boleh memeriksa repo atau konteks lain dengan perintah/tool read-only
  bila diperlukan.
- Deliverable Anda adalah rencana markdown yang disimpan di dalam workspace
  aktif pada `$planDirName/YYYY-MM-DD_HHMMSS-<slug>.md` (buat direktorinya
  bila perlu). Bila runtime memberikan path target spesifik, gunakan path
  persis itu.
''';

const String _planCraft = '''
Tulis rencana untuk implementer dengan nol konteks tentang codebase dan
selera yang meragukan. Rencana yang baik membuat implementasi menjadi jelas
— bila seseorang harus menebak, rencananya belum lengkap.

Struktur (sertakan seksi yang relevan):
- Tujuan — satu kalimat.
- Konteks saat ini / asumsi.
- Arsitektur / pendekatan yang diusulkan — 2-3 kalimat.
- Tugas langkah demi langkah. Setiap tugas kecil (2-5 menit kerja fokus),
  menyebut path file yang persis (`lib/models/user.dart`, bukan "file
  model"), menyertakan kode lengkap siap tempel bila kode diperlukan, dan
  perintah persis dengan output yang diharapkan untuk verifikasi.
- Tes / validasi — untuk tugas kode, ikuti siklus TDD per tugas: tulis tes
  yang gagal, jalankan untuk memastikan gagal, implementasikan minimal,
  jalankan untuk memastikan lulus, commit.
- Risiko, tradeoff, dan pertanyaan terbuka.

Prinsip: DRY, YAGNI, TDD, commit sering. Hindari tugas kabur ("tambahkan
autentikasi"), kode tidak lengkap ("tambahkan validasi di sini"), dan langkah
yang tidak bisa diverifikasi ("tes bahwa itu bekerja" — ganti dengan perintah
persis dan output yang diharapkan).

Gaya interaksi:
- Bila permintaan sudah cukup jelas, tulis rencananya langsung.
- Bila benar-benar kurang spesifikasi, ajukan satu pertanyaan klarifikasi
  singkat alih-alih menebak.
- Setelah menyimpan rencana, balas singkat dengan apa yang Anda rencanakan
  dan path yang disimpan, lalu tawarkan untuk mengeksekusinya (mis. via
  pengembangan berbasis subagent) — tetapi jangan mulai mengeksekusi di
  giliran ini.
''';

/// Menyusun prompt plan mode; [task] kosong meminta agent meng-infer tugas
/// dari konteks percakapan (Hermes `build_plan_prompt`, lihat #36821).
String buildPlanPrompt([String task = '']) {
  final t = task.trim();
  final taskBlock = t.isNotEmpty
      ? 'Tugas yang direncanakan:\n$t\n'
      : 'Tidak ada tugas eksplisit pada /plan — infer tugas dari konteks '
          'percakapan saat ini (hal yang sedang kita bahas atau kejar). '
          'Bila percakapan tidak mengimplikasikan tugas, ajukan pertanyaan '
          'klarifikasi singkat.\n';
  return '$planModeMarker\n\n$_planModeRules\n$taskBlock\n$_planCraft';
}

/// Parse input `/plan` atau `/plan <tugas>`; mengembalikan tugas ('' bila
/// tanpa argumen) atau null bila bukan perintah plan (termasuk `/plans`,
/// `/planning` — tidak pernah match prefix sebagian).
String? parsePlanCommand(String input) {
  final t = input.trim();
  if (t == '/plan') return '';
  if (t.startsWith('/plan ')) return t.substring('/plan '.length).trim();
  return null;
}

/// Nama file rencana `YYYY-MM-DD_HHMMSS-<slug>.md` ala Hermes
/// (`/plan` deliverable). Slug dari [task]: lowercase ASCII alnum, sisanya
/// jadi tanda hubung, dipangkas 40 char, kosong → `plan`.
String planFileName(DateTime nowUtc, String task) {
  String two(int v) => v.toString().padLeft(2, '0');
  final stamp = '${nowUtc.year.toString().padLeft(4, '0')}'
      '-${two(nowUtc.month)}-${two(nowUtc.day)}'
      '_${two(nowUtc.hour)}${two(nowUtc.minute)}${two(nowUtc.second)}';
  final slugBuf = StringBuffer();
  var lastHyphen = true;
  for (final c in task.toLowerCase().codeUnits) {
    final isAlnum = (c >= 0x30 && c <= 0x39) || (c >= 0x61 && c <= 0x7a);
    if (isAlnum) {
      slugBuf.writeCharCode(c);
      lastHyphen = false;
    } else if (!lastHyphen) {
      slugBuf.write('-');
      lastHyphen = true;
    }
  }
  var slug = slugBuf.toString();
  while (slug.endsWith('-')) {
    slug = slug.substring(0, slug.length - 1);
  }
  if (slug.length > 40) slug = slug.substring(0, 40);
  while (slug.endsWith('-')) {
    slug = slug.substring(0, slug.length - 1);
  }
  return '${stamp}-${slug.isEmpty ? 'plan' : slug}.md';
}

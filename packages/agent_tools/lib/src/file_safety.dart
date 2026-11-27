// Hermes parity: `agent/file_safety.py` — aturan keselamatan file bersama
// untuk tool tulis/baca/cari. Defense-in-depth, BUKAN security boundary:
// tool terminal berjalan sebagai user OS yang sama dan bisa membaca/menulis
// apa pun. Nilainya: penolakan jelas bagi model yang menghormati tool error
// + jejak audit yang terlihat.
//
// Deviasi sadar dari Hermes (didokumentasikan): Hermes melindungi
// HERMES_HOME lintas profile (auth.json, mcp-tokens/, vault/, dll.) plus
// device/NT-namespace Windows; Tiko ber-scope workspace + direktori state
// runtime `.tiko/` — set nama file kredensial disesuaikan layout Tiko
// (gateway.env, token/auth/credential JSON, key material). Tier approval
// ssh-config/rc tidak di-port: workspace jail sudah membatasi scope.
//
// Fail-closed: path sensitif ditolak di WRITE dan READ; grep tidak pernah
// memindai file sensitif (isi rahasia tidak pernah masuk konteks).
library;

import 'package:path/path.dart' as p;

/// Nama file env proyek pembawa rahasia (Hermes
/// `_BLOCKED_PROJECT_ENV_BASENAMES`; `.env.example` adalah substitusi
/// ber-bentuk sama yang justru didokumentasikan dan TIDAK diblokir).
const Set<String> blockedProjectEnvBasenames = {
  '.env',
  '.env.local',
  '.env.development',
  '.env.production',
  '.env.test',
  '.env.staging',
  '.envrc',
};

/// Ekstensi material kunci privat.
const Set<String> _privateKeyExtensions = {
  '.pem',
  '.key',
  '.p12',
  '.pfx',
  '.keystore',
};

/// Prefix nama kunci SSH privat (`.pub` = kunci publik, tidak diblokir).
const List<String> _privateKeyBasenames = [
  'id_rsa',
  'id_ed25519',
  'id_ecdsa',
  'id_dsa',
];

const String _defenseSuffix =
    ' (defense-in-depth — bukan security boundary; tool terminal masih '
    'dapat melewati).';

/// True bila [name] adalah nama file env proyek yang membawa rahasia.
/// Banding basename case-insensitive (Hermes: full Unicode case folding;
/// port Dart memakai `toLowerCase` — sufiks untuk id penutup skrip tidak
/// direplikasi).
bool isProjectEnvBasename(String name) =>
    blockedProjectEnvBasenames.contains(name.toLowerCase());

/// True bila [name] basename file sensitif: env rahasia, material kunci,
/// atau store kredensial (gateway.env, token/auth/credential/oauth JSON,
/// google_* ala Hermes). `.pub` dikecualikan dari kunci SSH.
bool isSensitiveBasename(String name) {
  final lower = name.toLowerCase();
  if (isProjectEnvBasename(lower) || lower == 'gateway.env') return true;
  if (lower.endsWith('.pub')) return false;
  for (final ext in _privateKeyExtensions) {
    if (lower.endsWith(ext)) return true;
  }
  for (final base in _privateKeyBasenames) {
    if (lower == base || lower.startsWith('$base.')) return true;
  }
  if (lower == 'auth.json' ||
      lower == 'credentials.json' ||
      lower.startsWith('credential') && lower.endsWith('.json') ||
      lower.startsWith('token') && lower.endsWith('.json') ||
      lower.endsWith('.token') ||
      lower.startsWith('oauth') && lower.endsWith('.json') ||
      lower == 'google_token.json' ||
      lower == 'google_client_secret.json' ||
      lower == 'google_oauth_pending.json') {
    return true;
  }
  return false;
}

/// True bila [relPath] mengarah ke state runtime `.tiko/` (config store,
/// usage anchor, published snapshot — dikelola host, bukan untuk agent).
bool isRuntimeStatePath(String relPath) {
  return p.split(p.normalize(relPath.trim())).contains('.tiko');
}

/// Penolakan WRITE untuk [relPath] (relatif workspace): null = boleh.
String? writeDenial(String relPath) {
  final trimmed = relPath.trim();
  if (trimmed.isEmpty) return null;
  final segments = p.split(p.normalize(trimmed));
  if (segments.contains('.tiko')) {
    return 'Write denied: "$trimmed" adalah state runtime .tiko/ yang '
        'dikelola host (config/cache/snapshot) — agent tidak menulisnya'
        '$_defenseSuffix';
  }
  final base = segments.last;
  if (isSensitiveBasename(base)) {
    return 'Write denied: "$trimmed" adalah file sistem/kredensial yang '
        'dilindungi$_defenseSuffix';
  }
  return null;
}

/// Penolakan READ untuk [relPath]: null = boleh. Env rahasia diblokir di
/// mana pun; `.env.example` adalah substitusi ber-dokumentasi.
String? readBlockError(String relPath) {
  final trimmed = relPath.trim();
  if (trimmed.isEmpty) return null;
  final base = p.basename(p.normalize(trimmed));
  if (isProjectEnvBasename(base)) {
    return 'Read denied: "$trimmed" adalah file env proyek pembawa rahasia '
        'dan tidak boleh dibaca. Gunakan .env.example sebagai contoh bentuk'
        '$_defenseSuffix';
  }
  if (isSensitiveBasename(base)) {
    return 'Read denied: "$trimmed" adalah file kredensial yang '
        'dilindungi — isinya tidak pernah masuk konteks$_defenseSuffix';
  }
  return null;
}

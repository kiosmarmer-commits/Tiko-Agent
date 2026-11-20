#!/usr/bin/env bash
# =============================================================================
# Tiko-Agent — installer sekali-perintah (E5, terinspirasi installer Hermes).
#
# Pemakaian:
#   bash install.sh                       # install lengkap ke ~/.local/bin
#   bash install.sh --prefix /opt/tiko    # lokasi biner kustom
#   bash install.sh --skip-dart-install   # pakai dart yang sudah ada
#   bash install.sh --no-path             # jangan ubah shell rc
#
# Yang dilakukan:
#   1. (Opsional) Pasang Dart SDK stabil (pin 3.13.4, sama dengan CI) ke
#      ~/.tiko/dart-sdk bila `dart` tidak ada / versinya < 3.8.
#   2. `dart pub get` untuk seluruh workspace.
#   3. Compile biner release: tiko, agentd, agent_cli (dart compile exe).
#   4. Pasang biner ke direktori prefix (default ~/.local/bin).
#   5. Smoke test `--help` untuk tiap biner.
#   6. Pastikan prefix biner ada di PATH (set shell rc, kecuali --no-path).
#
# Yang TIDAK dilakukan (jujur):
#   - Tidak memasang Flutter SDK / membangun client Flutter (apps/agent_flutter
#     butuh Flutter 3.47.5 — lihat INSTALL.md).
#   - Tidak mengonfigurasi provider LLM / API key — jalankan
#     `tiko setup --provider mock` (atau ollama) setelah install.
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
DART_VERSION="3.13.4"
DART_MIN_MAJOR=3
DART_MIN_MINOR=8
PREFIX="${HOME}/.local/bin"
SKIP_DART_INSTALL=0
NO_PATH=0

say()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m  ✓\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m  !\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m  ✗ %s\033[0m\n' "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prefix) PREFIX="$2"; shift 2 ;;
    --skip-dart-install) SKIP_DART_INSTALL=1; shift ;;
    --no-path) NO_PATH=1; shift ;;
    --help|-h)
      sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) die "argumen tidak dikenal: $1 (lihat --help)" ;;
  esac
done

# ---------------------------------------------------------------------------
# 1. Pastikan Dart SDK memadai.
# ---------------------------------------------------------------------------
dart_ok() {
  command -v dart >/dev/null 2>&1 || return 1
  local v
  v="$(dart --version 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)" || return 1
  local major minor
  major="${v%%.*}"
  minor="$(echo "$v" | cut -d. -f2)"
  [[ "$major" -gt "$DART_MIN_MAJOR" ]] ||
    { [[ "$major" -eq "$DART_MIN_MAJOR" ]] && [[ "$minor" -ge "$DART_MIN_MINOR" ]]; }
}

install_dart() {
  local os arch url zip tmpdir
  case "$(uname -s)" in
    Linux) os="linux" ;;
    Darwin) os="macos" ;;
    *) die "OS tidak didukung installer ini: $(uname -s) (lihat INSTALL.md)" ;;
  esac
  case "$(uname -m)" in
    x86_64|amd64) arch="x64" ;;
    aarch64|arm64) arch="arm64" ;;
    *) die "arsitektur tidak didukung: $(uname -m)" ;;
  esac
  url="https://storage.googleapis.com/dart-archive/channels/stable/release/${DART_VERSION}/sdk/dartsdk-${os}-${arch}-release.zip"
  local dest="${HOME}/.tiko"
  mkdir -p "$dest"
  zip="${dest}/dartsdk.zip"
  tmpdir="$(mktemp -d)"

  say "Mengunduh Dart SDK ${DART_VERSION} (${os}/${arch})..."
  if command -v curl >/dev/null 2>&1; then
    curl --fail --location --silent --show-error --output "$zip" "$url" ||
      die "unduhan gagal (curl)"
  elif command -v python3 >/dev/null 2>&1; then
    python3 - "$url" "$zip" <<'PYEOF'
import sys, urllib.request
url, out = sys.argv[1], sys.argv[2]
urllib.request.urlretrieve(url, out)
PYEOF
  else
    die "butuh curl atau python3 untuk mengunduh Dart SDK"
  fi

  say "Ekstrak ke ${dest}..."
  if command -v unzip >/dev/null 2>&1; then
    unzip -q -o "$zip" -d "$dest"
  else
    python3 - "$zip" "$dest" <<'PYEOF'
import sys, zipfile, os
zip_path, dest = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(zip_path) as z:
    z.extractall(dest)
PYEOF
  fi
  rm -f "$zip"
  rm -rf "$tmpdir"

  export PATH="${dest}/dart-sdk/bin:${PATH}"
  # Persist ke shell rc bila belum ada.
  local rc
  for rc in "${HOME}/.bashrc" "${HOME}/.zshrc"; do
    if [[ -f "$rc" ]] && ! grep -q '\.tiko/dart-sdk/bin' "$rc"; then
      printf '\n# Tiko-Agent (Dart SDK)\nexport PATH="%s/.tiko/dart-sdk/bin:$PATH"\n' "$HOME" >> "$rc"
      warn "PATH Dart ditambahkan ke ${rc} — buka terminal baru agar aktif"
    fi
  done
  dart_ok || die "Dart SDK terpasang tetapi tidak memadai"
  ok "Dart $(dart --version 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1) terpasang di ${dest}/dart-sdk"
}

say "Memeriksa Dart SDK..."
if dart_ok; then
  ok "Dart $(dart --version 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1) sudah ada"
elif [[ "$SKIP_DART_INSTALL" == 1 ]]; then
  die "--skip-dart-install diberikan tetapi dart tidak memadai"
else
  install_dart
fi

# ---------------------------------------------------------------------------
# 2. Resolusi dependensi workspace.
# ---------------------------------------------------------------------------
cd "$REPO_ROOT"
say "dart pub get (workspace)..."
dart pub get
ok "Dependensi ter-resolve"

# ---------------------------------------------------------------------------
# 3. Compile biner release.
# ---------------------------------------------------------------------------
say "Compile biner release (bisa beberapa menit)..."
mkdir -p build
dart compile exe apps/tiko/bin/tiko.dart -o build/tiko >/dev/null
ok "build/tiko"
dart compile exe apps/agentd/bin/agentd.dart -o build/agentd >/dev/null
ok "build/agentd"
dart compile exe apps/agent_cli/bin/agent_cli.dart -o build/agent_cli >/dev/null
ok "build/agent_cli"

# ---------------------------------------------------------------------------
# 4. Pasang ke prefix.
# ---------------------------------------------------------------------------
say "Memasang ke ${PREFIX}..."
mkdir -p "$PREFIX"
for b in tiko agentd agent_cli; do
  cp -f "build/$b" "${PREFIX}/$b"
  chmod +x "${PREFIX}/$b"
  ok "${PREFIX}/$b"
done

# ---------------------------------------------------------------------------
# 5. Smoke test.
# ---------------------------------------------------------------------------
run_with_timeout() {
  local secs="$1"; shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$secs" "$@"
  else
    "$@" &
    local pid=$!
    ( sleep "$secs" && kill "$pid" 2>/dev/null ) &
    local watcher=$!
    wait "$pid"
    local rc=$?
    kill "$watcher" 2>/dev/null
    wait "$watcher" 2>/dev/null
    return "$rc"
  fi
}

say "Smoke test --help (timeout 30s per biner)..."
for b in tiko agentd agent_cli; do
  run_with_timeout 30 "${PREFIX}/$b" --help >/dev/null 2>&1 ||
    die "biner $b gagal smoke --help (exit non-zero atau timeout)"
  ok "$b --help ok"
done

ensure_prefix_path() {
  case ":$PATH:" in
    *":${PREFIX}:"*)
      ok "${PREFIX} sudah ada di PATH"
      return
      ;;
  esac
  local rc target="" stamped=0
  export PATH="${PREFIX}:${PATH}"
  for rc in "${HOME}/.bashrc" "${HOME}/.zshrc" "${HOME}/.profile"; do
    if [[ -f "$rc" ]] && grep -qs "Tiko-Agent bin prefix" "$rc"; then
      stamped=1
    fi
  done
  if [[ "$stamped" == 1 ]]; then
    ok "PATH ${PREFIX} sudah terdaftar di shell rc"
  else
    for rc in "${HOME}/.bashrc" "${HOME}/.zshrc" "${HOME}/.profile"; do
      if [[ -f "$rc" ]]; then target="$rc"; break; fi
    done
    if [[ -z "$target" ]]; then
      target="${HOME}/.bashrc"
      : > "$target"
    fi
    printf '\n# Tiko-Agent bin prefix\nexport PATH="%s:$PATH"\n' "$PREFIX" >> "$target"
    warn "PATH biner ${PREFIX} ditambahkan ke ${target}"
    warn "Jalankan: source ${target}  (atau buka terminal baru) agar 'tiko' dikenali"
  fi
  case ":$PATH:" in
    *":${PREFIX}:"*) ok "PATH sesi berjalan memuat ${PREFIX}" ;;
    *) warn "${PREFIX} tak kena ke PATH sesi berjalan" ;;
  esac
}

if [[ "$NO_PATH" == 1 ]]; then
  case ":$PATH:" in
    *":${PREFIX}:"*) ok "${PREFIX} sudah ada di PATH" ;;
    *) warn "--no-path: ${PREFIX} BELUM di PATH - atur sendiri: export PATH=\"${PREFIX}:\$PATH\"" ;;
  esac
else
  ensure_prefix_path
fi

cat <<'EOF'

Instalasi selesai. Langkah berikutnya:

  tiko setup --provider mock     # konfigurasi awal (tanpa LLM nyata)
  tiko settings                  # menu pengaturan interaktif di terminal
  tiko doctor                    # periksa kesehatan runtime
  tiko chat                      # mulai percakapan

Provider nyata (Ollama / API cloud): lihat INSTALL.md bagian konfigurasi.
Client Flutter (opsional): lihat INSTALL.md — butuh Flutter 3.47.5.
EOF

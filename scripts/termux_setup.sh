#!/usr/bin/env bash
# Termux helpers (run inside Termux)
set -euo pipefail
pkg update -y
pkg install -y dart git curl
# optional: ollama not always available on Termux — use remote OLLAMA_BASE
cd "$(dirname "$0")/.."
dart pub get
echo "Jalankan: ./scripts/run_agentd.sh"
echo "Wake-lock (opsional): termux-wake-lock"

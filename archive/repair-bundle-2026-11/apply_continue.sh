#!/usr/bin/env bash
set -euo pipefail
ROOT="${1:-.}"
B="$(cd "$(dirname "$0")/.." && pwd)"
cp "$B/packages/tiko_runtime/lib/src/tiko_runtime.dart" \
   "$ROOT/packages/tiko_runtime/lib/src/tiko_runtime.dart"
mkdir -p "$ROOT/docs"
cp "$B/docs/STATUS-CONTINUE-2026-11-10.md" "$ROOT/docs/"
echo "Applied P1-09 isolation patch. Run validate.sh"

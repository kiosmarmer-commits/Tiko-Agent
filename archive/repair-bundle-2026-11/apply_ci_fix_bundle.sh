#!/usr/bin/env bash
set -euo pipefail
ROOT="${1:-.}"
BUNDLE="$(cd "$(dirname "$0")/.." && pwd)"
if [[ ! -f "$ROOT/pubspec.yaml" ]]; then
  echo "error: $ROOT is not Tiko-Agent root" >&2
  exit 1
fi
copy() {
  local rel="$1"
  mkdir -p "$(dirname "$ROOT/$rel")"
  cp "$BUNDLE/$rel" "$ROOT/$rel"
  echo "copied $rel"
}
copy packages/agent_tools/lib/src/subagent.dart
copy packages/agent_tools/test/subagent_test.dart
copy packages/agent_tools/test/web_search_tavily_test.dart
copy packages/agent_gateway/lib/src/http_api.dart
copy packages/agent_gateway/lib/src/email_gateway.dart
copy packages/tiko_runtime/lib/src/tiko_runtime.dart
copy apps/agent_flutter/test/admin_ui_test.dart
copy docs/STATUS-CI-FIX-2026-11-10.md
echo
echo "Applied. Run: dart pub get && bash scripts/validate.sh && bash scripts/flutter_validate.sh"

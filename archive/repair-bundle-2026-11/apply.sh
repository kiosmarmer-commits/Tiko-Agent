#!/usr/bin/env bash
set -euo pipefail
ROOT="${1:-.}"
B="$(cd "$(dirname "$0")/.." && pwd)"
[[ -f "$ROOT/pubspec.yaml" ]] || { echo "not tiko root"; exit 1; }
for f in \
  packages/agent_tools/lib/src/subagent.dart \
  packages/agent_tools/test/subagent_test.dart \
  packages/agent_tools/test/web_search_tavily_test.dart \
  packages/agent_gateway/lib/src/http_api.dart \
  packages/agent_gateway/lib/src/email_gateway.dart \
  packages/agent_gateway/test/email_gateway_test.dart \
  packages/tiko_runtime/lib/src/tiko_runtime.dart \
  apps/agent_flutter/test/admin_ui_test.dart
do
  mkdir -p "$(dirname "$ROOT/$f")"
  cp "$B/$f" "$ROOT/$f"
  echo "copied $f"
done
echo "Done. Run validate.sh"

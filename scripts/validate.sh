#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

echo '== shell and Python validation scripts =='
for script in scripts/*.sh; do bash -n "$script"; done
python3 -m compileall -q scripts tools/mock_mcp_server

echo '== resolve workspace dependencies =='
dart pub get

echo '== strict static analysis =='
for dir in packages/* apps/agentd apps/tiko apps/agent_cli; do
  echo "== analyze: $dir =="
  (cd "$dir" && dart analyze --fatal-warnings)
done

echo '== package and executable tests =='
for dir in packages/* apps/agentd apps/tiko apps/agent_cli; do
  if [[ -d "$dir/test" ]]; then
    echo "== $dir =="
    (cd "$dir" && dart test --reporter expanded)
  fi
done

echo '== deterministic calculator =='
calc="$(dart run apps/tiko/bin/tiko.dart calc 5+1)"
printf '%s\n' "$calc"
test "$calc" = '6'

echo '== setup/config smoke =='
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
dart run apps/tiko/bin/tiko.dart --config "$tmp/mock/agent.yaml" setup --provider mock
dart run apps/tiko/bin/tiko.dart --config "$tmp/ollama/agent.yaml" setup --provider ollama
dart run apps/tiko/bin/tiko.dart --config "$tmp/mock/agent.yaml" config validate
dart run apps/tiko/bin/tiko.dart --config "$tmp/ollama/agent.yaml" config validate

echo '== CLI chat smoke =='
chat="$(dart run apps/tiko/bin/tiko.dart chat halo)"
printf '%s\n' "$chat"
grep -qi 'mock agent' <<< "$chat"

echo '== compile entrypoints =='
mkdir -p "$tmp/build"
dart compile exe apps/tiko/bin/tiko.dart -o "$tmp/build/tiko"
dart compile exe apps/agentd/bin/agentd.dart -o "$tmp/build/agentd"
dart compile exe apps/agent_cli/bin/agent_cli.dart -o "$tmp/build/agent_cli"

echo '== daemon lifecycle and HTTP API smoke =='
bash scripts/smoke_agentd.sh

echo '== Flutter client validation =='
bash scripts/flutter_validate.sh

echo 'VALIDATION PASS'

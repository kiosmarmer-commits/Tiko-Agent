#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

command -v dart >/dev/null || { echo 'dart SDK is required' >&2; exit 127; }
command -v curl >/dev/null || { echo 'curl is required' >&2; exit 127; }

tmp="$(mktemp -d)"
port="${TIKO_SMOKE_PORT:-18789}"
token="tiko-ci-smoke-token-not-for-production"
pid=""
cleanup() {
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
    kill -TERM "$pid" 2>/dev/null || true
    for _ in $(seq 1 40); do
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.25
    done
    kill -KILL "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  fi
  rm -rf "$tmp"
}
trap cleanup EXIT

config="$tmp/config/agent.yaml"
timeout 180 dart run apps/tiko/bin/tiko.dart --config "$config" setup --provider mock

TIKO_CONFIG="$config" API_PORT="$port" API_TOKEN="$token" \
  dart run apps/agentd/bin/agentd.dart --api >"$tmp/agentd.log" 2>&1 &
pid=$!
base="http://127.0.0.1:$port"
ready=0
for _ in $(seq 1 60); do
  if curl --silent --fail --max-time 2 "$base/health" >/dev/null; then
    ready=1
    break
  fi
  if ! kill -0 "$pid" 2>/dev/null; then
    cat "$tmp/agentd.log" >&2
    echo 'agentd exited before the API became ready' >&2
    exit 1
  fi
  sleep 0.25
done
if [[ "$ready" != 1 ]]; then
  cat "$tmp/agentd.log" >&2
  echo 'agentd API readiness timed out' >&2
  exit 1
fi

auth="Authorization: Bearer $token"
test -s "$tmp/data/api.token"
if command -v stat >/dev/null 2>&1 && stat -c '%a' "$tmp/data/api.token" >/dev/null 2>&1; then
  test "$(stat -c '%a' "$tmp/data/api.token")" = '600'
fi
curl --silent --show-error --fail --max-time 20 -H "$auth" "$base/v1/doctor" | grep -q '"ram"'
curl --silent --show-error --fail --max-time 20 -H "$auth" "$base/v1/approvals" | grep -q '"approvals"'
cli_approvals="$(timeout 120 dart run apps/tiko/bin/tiko.dart --config "$config" approvals)"
printf '%s\n' "$cli_approvals" | grep -q 'tidak ada approval'
reply="$(curl --silent --show-error --fail --max-time 20 -H "$auth" -H 'Content-Type: application/json' \
  -d '{"text":"halo","session_key":"ci:smoke","user_key":"ci"}' \
  "$base/v1/messages")"
printf '%s\n' "$reply" | grep -qi 'mock agent'

stop_result="$(timeout 120 dart run apps/tiko/bin/tiko.dart --config "$config" daemon stop)"
printf '%s\n' "$stop_result" | grep -q 'stopped'
# Bounded graceful-exit wait: an unbounded wait here previously stalled CI.
graceful=0
for _ in $(seq 1 60); do
  if ! kill -0 "$pid" 2>/dev/null; then
    graceful=1
    break
  fi
  sleep 0.5
done
if [[ "$graceful" != 1 ]]; then
  cat "$tmp/agentd.log" >&2
  echo 'agentd did not exit after daemon stop' >&2
  kill -KILL "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  pid=""
  exit 1
fi
status=0
set +e
wait "$pid"
status=$?
set -e
pid=""
if [[ "$status" != 0 ]]; then
  cat "$tmp/agentd.log" >&2
  echo "agentd exited with status $status" >&2
  exit 1
fi
test ! -f "$tmp/data/tiko.lock"
echo 'AGENTD API + GRACEFUL SHUTDOWN SMOKE PASS'

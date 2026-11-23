#!/usr/bin/env bash
# F7.1 (docs/15 §8) — eval gate rilis: gerbang kualitas deterministik.
#
# Tahap offline (default, tanpa LLM asli, 100% deterministik):
#   1. Gerbang guard: harness prompt-injection Indonesia (40 kasus) —
#      `dart test packages/agent_security/test/injection_eval_test.dart`.
#   2. Gerbang task: dataset emas runtime di atas provider mock —
#      `dart test packages/tiko_runtime/test/f7_eval_gate_test.dart`.
#
# Fallback live (sesuai keputusan arah: "offline first"):
# bila tahap offline gagal DAN env TIKO_EVAL_LIVE_CONFIG menunjuk file config
# dengan provider LLM asli, gate beralih ke eval live (TIKO_EVAL_LIVE=1) yang
# menjalankan `eval_live.jsonl` di atas provider sungguhan — butuh approval,
# durasi/biaya kecil (3 task, max_tokens dibatasi). Tanpa config live, hasil
# offline adalah hasil final gate.
set -uo pipefail

fail=0

run_eval() {
  local label=$1
  shift
  echo "== eval gate: $label =="
  "$@" || fail=1
}

run_eval "guard prompt-injection (40 kasus deterministik)" \
  dart test packages/agent_security/test/injection_eval_test.dart --reporter expanded

run_eval "task eval runtime (mock offline deterministik)" \
  dart test packages/tiko_runtime/test/f7_eval_gate_test.dart --reporter expanded

if [[ $fail -ne 0 ]]; then
  live_config="${TIKO_EVAL_LIVE_CONFIG:-}"
  if [[ -n "$live_config" && -f "$live_config" ]]; then
    echo "Offline gagal — fallback eval live provider asli (TIKO_EVAL_LIVE_CONFIG=$live_config)"
    run_eval "task eval runtime (provider LLM asli)" \
      env TIKO_EVAL_LIVE=1 TIKO_EVAL_LIVE_CONFIG="$live_config" \
      dart test packages/tiko_runtime/test/f7_eval_gate_test.dart --reporter expanded
  else
    echo "Offline gagal; fallback live tidak tersedia."
    echo "Set TIKO_EVAL_LIVE_CONFIG=<config.yaml dengan provider asli> untuk mengaktifkan fallback."
    exit "$fail"
  fi
fi

if [[ $fail -ne 0 ]]; then
  echo "EVAL GATE: GAGAL"
else
  echo "EVAL GATE: LOLOS"
fi
exit "$fail"

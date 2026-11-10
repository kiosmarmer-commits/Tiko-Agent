#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
export AGENT_UI="${AGENT_UI:-1}"
dart pub get
exec dart run apps/agentd/bin/agentd.dart --api "$@"

#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
dart pub get
mkdir -p build
dart compile exe apps/tiko/bin/tiko.dart -o build/tiko
dart compile exe apps/agentd/bin/agentd.dart -o build/agentd
dart compile exe apps/agent_cli/bin/agent_cli.dart -o build/agent_cli
echo "Binaries: build/tiko, build/agentd, build/agent_cli"

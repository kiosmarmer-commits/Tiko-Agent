#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

if ! command -v flutter >/dev/null 2>&1; then
  echo 'ERROR: Flutter SDK is required for the complete Flutter validation gate.' >&2
  exit 127
fi

cd apps/agent_flutter
flutter pub get
flutter analyze
flutter test --reporter expanded
flutter build web --release

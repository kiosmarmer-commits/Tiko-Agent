#!/usr/bin/env bash
# Apply Parallel Search + search key wiring patches onto a clean main checkout.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "Applying patches from patches/ ..."
git apply --verbose patches/2026-11-20-parallel-web-search.patch
git apply --verbose patches/2026-11-20-builtin-search-keys.patch

echo "OK. Run: dart analyze packages/agent_tools && dart test packages/agent_tools"
echo "Set PARALLEL_API_KEY (and optional BRAVE/EXA/FIRECRAWL keys) before using web_search."

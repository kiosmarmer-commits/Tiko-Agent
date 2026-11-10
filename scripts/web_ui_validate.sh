#!/usr/bin/env bash
set -euo pipefail
node --check apps/agentd/web/app.js
node --test apps/agentd/web/app.test.cjs

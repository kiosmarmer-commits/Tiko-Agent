# Tiko continue fix — P1-09 isolation nyata

File utama:
- `packages/tiko_runtime/lib/src/tiko_runtime.dart`

Perubahan:
1. `chatWithStatus(..., gateOverride, configOverride)`
2. `_AllowlistToolGate` untuk allowlist subagent
3. `_runSubagent` memakai gate + AgentConfig dari `SubagentBudget`

Apply:
```bash
bash scripts/apply_continue.sh /path/to/Tiko-Agent
```

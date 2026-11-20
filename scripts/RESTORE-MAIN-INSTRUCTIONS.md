# URGENT: Restore main after PR #115 corruption

PR #115 was merged with PLACEHOLDER content, wiping `web_search.dart` and emptying `builtin.dart`.

## Fix (run locally)

```bash
cd Tiko-Agent
git fetch origin
git checkout main

# 1) Restore good files from commit before corruption
git checkout 3f1d0ebf59b6 -- packages/agent_tools/lib/src/web_search.dart packages/agent_tools/lib/src/builtin.dart

# 2) Apply Parallel Search patches from this branch
git checkout fix/restore-web-search-parallel -- patches/
git apply patches/2026-11-20-parallel-web-search.patch
git apply patches/2026-11-20-builtin-search-keys.patch

# 3) Verify
dart analyze packages/agent_tools

# 4) Commit & push
git add packages/agent_tools/lib/src/web_search.dart packages/agent_tools/lib/src/builtin.dart
git commit -m "fix: restore web_search + builtin after PR #115; add Parallel Search"
git push origin main
```

Or use the zip from the agent chat (`tiko-parallel-search-patch.zip`) and copy the full dart files.

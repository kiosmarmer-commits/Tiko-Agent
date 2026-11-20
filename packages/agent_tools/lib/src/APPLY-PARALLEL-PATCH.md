# Apply Parallel Search Patch

Branch files `web_search.dart` / `builtin.dart` may be incomplete due to transfer limits.

## Quick apply (from main)

```bash
cd Tiko-Agent
git checkout main
# Download full patch zip from the agent deliverable, or copy from PR artifacts
unzip tiko-parallel-search-patch.zip -d /tmp/tiko_patch
cp /tmp/tiko_patch/packages/agent_tools/lib/src/web_search.dart packages/agent_tools/lib/src/
cp /tmp/tiko_patch/packages/agent_tools/lib/src/builtin.dart packages/agent_tools/lib/src/
cp /tmp/tiko_patch/docs/HERMES-TOOLS-GAP-ANALYSIS-2026-11-20.md docs/
dart analyze packages/agent_tools
```

## Env

```bash
export PARALLEL_API_KEY=your_key
# optional: BRAVE_SEARCH_API_KEY, EXA_API_KEY, FIRECRAWL_API_KEY, TAVILY_API_KEY, ...
```

## What changes

1. **web_search.dart** — provider `parallel` (`api.parallel.ai/v1/search`, header `x-api-key`)
2. **builtin.dart** — `createBuiltinTools` accepts and forwards `parallelApiKey`, `braveApiKey`, `exaApiKey`, `firecrawlApiKey`
3. **docs** — gap analysis vs Hermes hermestools

# Skill: Dream Cycle (项目特定)

> DreamVault dream run / 调试 / 部署 skill. 给 mavis agent 用, 端到端跑 dream.

## dream run 端到端

```bash
cd /Users/biomatrix/Desktop/APP/DreamVault
make build                        # 编译 dream CLI
swift run dream run --vault <path>  # 跑一次 dream 周期
swift run dream status --vault <path>  # 看 vault 状态
```

## 配置 5 层 (GlobalOptions.resolvedRuntimeConfig)

1. **CLI flag** (--llm / --vault / --verbose)
2. **vault config** (`.dream/config.json` in vault root)
3. **settings** (UserDefaults `DreamSettings`)
4. **env vars** (DREAMVAULT_LLM / OLLAMA_BASE_URL / OLLAMA_MODEL)
5. **hardcoded defaults**

`RuntimeContext.runtimeContext()` 暴露 5 层合并结果 + privacy 守门.

## 真实 LLM provider

- `OllamaProvider` (OpenAI 兼容 `/v1/chat/completions`)
- `OllamaNativeProvider` (P3-5 `/api/chat` + `format: json_schema`, 优先)
- `MockLLMProvider` (test / debug, 走 2 步快速路径)
- `BudgetedLLMProvider` (包装, 走 BudgetManager 预算检查)

## LLM 选型

- 本机 Ollama: `DREAMVAULT_LLM=ollama OLLAMA_MODEL=gemma2:2b`
- Mock: `DREAMVAULT_LLM=mock` (default)
- OpenAI: `DREAMVAULT_LLM=openai-compat` + 隐私 consent (RuntimeConfigError.cloudProviderRequiresConsent)

## 真量化评测 (P3-8)

```bash
OLLAMA_MODEL=gemma2:2b make eval-ollama-verify       # 75 case 2-3 分钟
OLLAMA_MODEL=gemma2:2b make eval-ollama-contradiction # 25 case 1 分钟
```

报告: `docs/eval-ollama-{verify,contradiction}-YYYY-MM-DD.md`

## 调试 dream crash

1. `make build` 编译 + `swift run dream run --vault <path> --verbose`
2. 看 stderr (Consolidator / Gatherer / Decayer / Persister 错误)
3. `docs/dream-report-YYYY-MM-DD.md` (Persister 写) — 末尾 ## Prescreen 段
4. `Tests/DreamEngineTests/` 跑对应单测定位

## 启动 launchd 任务 (夜间调度)

```bash
make install                          # 装 launchd plist + bootstrap
swift run dream status                # 看 enabled + nextRunAt + lastError
swift run dream scheduler --disable   # 停
```

## 跟 worktree pattern 配合

- coder rein 走 worktree, 改完 merge + tag
- 跑 dream 测: `swift run dream run --vault <tmp test vault>`
- 不要拿生产 vault 跑 (会污染 real data)

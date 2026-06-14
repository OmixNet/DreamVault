# Workflow: CI Integration

> DreamVault GitHub Actions 持续集成 workflow 详解.

## Two workflows

### ci-smoke.yml (PR/push)

- **触发**: push main / PR / manual
- **runner**: macos-14 (Apple Silicon, 评测 NLEmbeddingProvider 需 arm64)
- **跑时**: ~30s
- **步骤**:
  1. `actions/checkout@v4`
  2. `sudo xcode-select -s /Applications/Xcode_15.4.app`
  3. `bash scripts/ci-smoke.sh`
  4. `actions/upload-artifact@v4` 报告 (`/tmp/dv-ci-eval.md`)
- **不跑真 Ollama** (留给 nightly)

### nightly-eval.yml (cron 03:00 UTC)

- **触发**: cron `0 3 * * *` + manual
- **runner**: macos-14
- **跑时**: 5-10 分钟
- **步骤**:
  1. `actions/checkout@v4`
  2. `xcode-select`
  3. `brew install ollama` + `nohup ollama serve` + `ollama pull gemma2:2b`
  4. `bash scripts/nightly-eval.sh` (env: OLLAMA_BASE_URL / OLLAMA_MODEL)
  5. `actions/upload-artifact@v4` 报告
  6. 可选: commit summary back to repo (用 github-actions[bot] 身份)

## 阈值 (nightly-eval.sh 校验)

- verify ≥ 75% (baseline 88%, 留 13% buffer)
- contradiction ≥ 80% (baseline 92%, 留 12% buffer)
- 退化 exit 1 (cron 邮件 / Slack 报警)

## 本地同步

- `make ci-smoke` (跟 ci-smoke.yml 同款)
- `make nightly-eval` (跟 nightly-eval.yml 同款, 需本机 Ollama daemon)

## Models

- 当前: **gemma2:2b** (Q4_0 1.6GB, Apple Silicon 5-10 tok/s)
- 评审 §2.3 推荐: qwen2.5:3b (同档位 ≤3B, 适合裁判任务)
- 备选: llama3.1:8b (大模型, 慢但 P/R/F1 可能更高)

## 输出路径

- 报告: `docs/nightly-eval/{verify,contradiction,summary}-YYYY-MM-DD.md`
- mock 报告 (CI smoke): `/tmp/dv-ci-eval.md` (artifact)

## 跟其他 reins 协调

- release: tag 之前 `make ci-smoke` 必须全过
- verifier: 跟 nightly-eval 共享 baseline (gemma2:2b 88% / 92%)
- coder: PR 之前本地 `make ci-smoke` 自测

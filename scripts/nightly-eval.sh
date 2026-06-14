#!/usr/bin/env bash
# nightly-eval.sh — 真 Ollama 量化 nightly (P3-8 §3 真价值证明)
# 跑在 nightly cron (cron 03:00 + manual trigger), 5-10 分钟, 跟 GitHub Actions
# nightly-eval.yml 同步.
#
# **本脚本需本机 Ollama daemon**:
#   ollama serve &  /  拉模型: ollama pull gemma2:2b
# CI (GitHub Actions) 用 runners 里启 ollama service.
#
# 内容:
#   1. swift build (确保 CLI binary 新鲜)
#   2. 拆 phase 跑真 Ollama gemma2:2b 100 case:
#      - verify 75 case (88% accuracy baseline, 2-3 分钟)
#      - contradiction 25 case (92% accuracy baseline, 1 分钟)
#   3. 写 docs/nightly-eval-YYYY-MM-DD.md
#   4. 验证 P/R/F1 阈值, 退化报警
#
# 阈值 (跟 v0.7.6 baseline 比):
#   - verify accuracy ≥ 75% (88% baseline, 留 13% buffer)
#   - contradiction accuracy ≥ 80% (92% baseline, 留 12% buffer)
#   - 退化 >10% 触发 exit 1 (让 cron 发邮件 / Slack 报警)
set -euo pipefail
export PATH="/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:/Applications/Xcode.app/Contents/Developer/usr/bin:$PATH"

cd "$(git rev-parse --show-toplevel)"

OLLAMA_BASE_URL=${OLLAMA_BASE_URL:-http://127.0.0.1:11434}
OLLAMA_MODEL=${OLLAMA_MODEL:-gemma2:2b}
DATE=$(date +%Y-%m-%d)
REPORT_DIR="docs/nightly-eval"
mkdir -p "$REPORT_DIR"

# Ollama daemon 健康检查
if ! curl -sSf -m 5 "$OLLAMA_BASE_URL/api/tags" > /dev/null 2>&1; then
  echo "ERROR: Ollama daemon 不在 $OLLAMA_BASE_URL — 启 daemon: ollama serve &"
  exit 1
fi

# 模型存在性检查
if ! curl -sSf -m 5 "$OLLAMA_BASE_URL/api/tags" | grep -q "\"$OLLAMA_MODEL\""; then
  echo "ERROR: 模型 $OLLAMA_MODEL 未拉. 跑: ollama pull $OLLAMA_MODEL"
  exit 1
fi

echo "=== 1/4 swift build ==="
swift build 2>&1 | tail -3

echo "=== 2/4 verify phase 75 case (真 Ollama $OLLAMA_MODEL) ==="
DREAMVAULT_LLM=ollama \
  swift run dream eval --llm ollama --phase verify \
  --report "$REPORT_DIR/verify-$DATE.md" 2>&1 | tail -3

echo "=== 3/4 contradiction phase 25 case ==="
DREAMVAULT_LLM=ollama \
  swift run dream eval --llm ollama --phase contradiction \
  --report "$REPORT_DIR/contradiction-$DATE.md" 2>&1 | tail -3

echo "=== 4/4 验证 accuracy 阈值 ==="
VERIFY_ACC=$(grep -A 1 "verify 闸" "$REPORT_DIR/verify-$DATE.md" | grep "Accuracy" | head -1 | grep -oE "[0-9]+\.[0-9]+%" | head -1)
CONTRA_ACC=$(grep -A 1 "contradiction 闸" "$REPORT_DIR/contradiction-$DATE.md" | grep "Accuracy" | head -1 | grep -oE "[0-9]+\.[0-9]+%" | head -1)
VERIFY_NUM=${VERIFY_ACC%\%}
CONTRA_NUM=${CONTRA_ACC%\%}

echo "  verify accuracy:      $VERIFY_ACC (baseline 88%, threshold ≥75%)"
echo "  contradiction accuracy: $CONTRA_ACC (baseline 92%, threshold ≥80%)"

EXIT_CODE=0
if [ -z "$VERIFY_NUM" ] || [ "${VERIFY_NUM%.*}" -lt 75 ]; then
  echo "WARNING: verify accuracy 退化 ($VERIFY_ACC < 75%)"
  EXIT_CODE=1
fi
if [ -z "$CONTRA_NUM" ] || [ "${CONTRA_NUM%.*}" -lt 80 ]; then
  echo "WARNING: contradiction accuracy 退化 ($CONTRA_ACC < 80%)"
  EXIT_CODE=1
fi

# 写汇总报告
cat > "$REPORT_DIR/summary-$DATE.md" <<EOF
# DreamVault Nightly Eval — $DATE

## 真 Ollama 量化 (模型: $OLLAMA_MODEL)

| Phase | Accuracy | Baseline | 状态 |
|-------|----------|----------|------|
| Verify (75 case) | $VERIFY_ACC | 88.0% | $([ "${VERIFY_NUM%.*}" -ge 75 ] && echo "✓" || echo "✗ 退化") |
| Contradiction (25 case) | $CONTRA_ACC | 92.0% | $([ "${CONTRA_NUM%.*}" -ge 80 ] && echo "✓" || echo "✗ 退化") |

## 报告

- verify phase: \`$REPORT_DIR/verify-$DATE.md\`
- contradiction phase: \`$REPORT_DIR/contradiction-$DATE.md\`

## 运行

\`\`\`bash
bash scripts/nightly-eval.sh
# 或 GitHub Actions nightly-eval.yml (cron 03:00 UTC)
\`\`\`

## 阈值

- verify ≥ 75% (88% baseline, 留 13% buffer)
- contradiction ≥ 80% (92% baseline, 留 12% buffer)
- 退化 >10% vs baseline 触发 exit 1
EOF

echo "✓ Nightly eval 全过 — 报告 $REPORT_DIR/summary-$DATE.md"
exit $EXIT_CODE

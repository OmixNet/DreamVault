#!/usr/bin/env bash
# ci-smoke.sh — CI smoke test (P3-8 follow-up)
# 跑在 PR / push 触发, ~30s, 跟 GitHub Actions ci-smoke.yml 同步.
# 退出码: 0 = pass, 1 = fail.
#
# 内容:
#   1. swift build (编译整个 package, 含 DreamEngine + dream CLI)
#   2. swift test (623+ tests, ~20s)
#   3. 跑 mock provider P3-8 评测集 (100 case, ~3s, 验证管道连通性)
#
# **不**跑真 Ollama 量化 (那是 nightly-eval.sh 的事, 5-10 分钟 + 本机 daemon).
set -euo pipefail
export PATH="/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:/Applications/Xcode.app/Contents/Developer/usr/bin:$PATH"

# 切到仓库根 (避免 caller 在子目录)
cd "$(git rev-parse --show-toplevel)"

echo "=== 1/3 swift build ==="
swift build 2>&1 | tail -3

echo "=== 2/3 swift test ==="
swift test 2>&1 | grep -E "Executed.*tests" | tail -1

echo "=== 3/3 make eval (mock provider 100 case) ==="
# 跑 mock 100 case, 验证 P3-8 评测管道连通性 (~3s).
# 真 LLM 跑 make eval-ollama-verify / make eval-ollama-contradiction 是 nightly 的事.
DREAMVAULT_LLM=mock swift run dream eval --llm mock --report /tmp/dv-ci-eval.md 2>&1 | tail -3

# 验证报告头有 100 case
if ! grep -q "评测 case 数: 100" /tmp/dv-ci-eval.md; then
  echo "ERROR: 评测报告期望 100 case, 实际 $(grep '评测 case 数' /tmp/dv-ci-eval.md)"
  exit 1
fi
echo "✓ CI smoke 全过"

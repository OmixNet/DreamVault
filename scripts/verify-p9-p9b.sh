#!/bin/bash
# verify-p9-p9b.sh — 验证 v0.5.0-rc3 + rc4 关键路径
# 用法: bash scripts/verify-p9-p9b.sh
# 退出码: 0 = 全过, 1 = 有失败
#
# 给自己用, 不给 CI. 写得可读可改, 不追求鲁棒.
set -e

VAULT=$(mktemp -d -t dv-verify-XXXX)
echo "=== 在 $VAULT 构造测试 vault ==="
cd "$VAULT"
git init -q -b main
git config user.email "verify@dreamvault.local"
git config user.name "Verify"
echo "MEMORY.md" > MEMORY.md
git add . && git commit -q -m "init"

echo "=== 1. 测 dream CLI (binary 必须先 build 一次) ==="
# 优先用 worktree 里的 build, 找不到就走完整 swift build
DREAM_BIN="/tmp/dv-p9c/.build/debug/dream"
if [ ! -x "$DREAM_BIN" ]; then
  DREAM_BIN="/tmp/dv-p9b/.build/debug/dream"
fi
if [ ! -x "$DREAM_BIN" ]; then
  echo "  ⚠ dream binary 不在标准 worktree 路径, 跳过 CLI smoke test"
  echo "  (要补跑就在 /tmp/dv-p9c 或 main worktree 里 swift build 一次)"
else
  "$DREAM_BIN" status --vault "$VAULT"
  echo "  ✓ dream status OK"
fi

echo "=== 2. 测 Rollback confirmation (单元测试) ==="
# 优先 /tmp/dv_p9c_test, 找不到就用 main worktree 的 swift test --filter
# 拿 XCTest 真实 "Executed N tests" 行, 跟预期 3 对比
EXPECTED_ROLLBACK=3
if [ -x "/tmp/dv_p9c_test" ]; then
  ROLLBACK_OUT=$(/tmp/dv_p9c_test --filter RollbackConfirmationTests 2>&1)
else
  echo "  ⚠ /tmp/dv_p9c_test 不存在, 改用 swift test (会跑全套, 慢)"
  ROLLBACK_OUT=$(cd /Users/biomatrix/Desktop/APP/DreamVault && swift test --filter RollbackConfirmationTests 2>&1)
fi
ROLLBACK_COUNT=$(echo "$ROLLBACK_OUT" | grep -E "Executed [0-9]+ tests" | head -1 | grep -oE "[0-9]+" | head -1)
if [ -z "$ROLLBACK_COUNT" ]; then
  echo "  ✗ 拿不到 'Executed N tests' 输出, 单元测试没跑成功"
  echo "$ROLLBACK_OUT" | tail -10
  exit 1
fi
echo "  期望 $EXPECTED_ROLLBACK tests, 实际 $ROLLBACK_COUNT tests"
if [ "$ROLLBACK_COUNT" -ge "$EXPECTED_ROLLBACK" ]; then
  echo "  ✓ RollbackConfirmationTests pass"
else
  echo "  ✗ tests 数量不足 (< $EXPECTED_ROLLBACK)"
  exit 1
fi

echo "=== 3. 测 RawImporter (单元测试) ==="
EXPECTED_RAW=9
if [ -x "/tmp/dv_p9c_test" ]; then
  RAW_OUT=$(/tmp/dv_p9c_test --filter RawImporterTests 2>&1)
else
  RAW_OUT=$(cd /Users/biomatrix/Desktop/APP/DreamVault && swift test --filter RawImporterTests 2>&1)
fi
RAW_COUNT=$(echo "$RAW_OUT" | grep -E "Executed [0-9]+ tests" | head -1 | grep -oE "[0-9]+" | head -1)
if [ -z "$RAW_COUNT" ]; then
  echo "  ✗ 拿不到 'Executed N tests' 输出, 单元测试没跑成功"
  echo "$RAW_OUT" | tail -10
  exit 1
fi
echo "  期望 $EXPECTED_RAW tests, 实际 $RAW_COUNT tests"
if [ "$RAW_COUNT" -ge "$EXPECTED_RAW" ]; then
  echo "  ✓ RawImporterTests pass"
else
  echo "  ✗ tests 数量不足 (< $EXPECTED_RAW)"
  exit 1
fi

echo "=== 4. GUI 流程 (拖拽 / 菜单) 跳过, 走手工 ==="
echo "  - 拖拽: 启动 .app, Finder 拖 .md 进 VaultBrowser, 看 raw/ 是否出现文件 + banner"
echo "  - 菜单 Cmd-I: 同上, File → Import to raw… 选文件"
echo "  - Rollback 二次确认: DreamPanel 点 Rollback, 看 confirmationDialog 是否先弹"

echo "=== 5. 验 tags 存在 ==="
git -C /Users/biomatrix/Desktop/APP/DreamVault tag -l | grep -E "v0\.5\.0-rc[34]" || {
  echo "  ✗ tags 缺失"
  exit 1
}
echo "  ✓ v0.5.0-rc3 + v0.5.0-rc4 tags 存在"

echo "=== 全部过完 ==="
rm -rf "$VAULT"

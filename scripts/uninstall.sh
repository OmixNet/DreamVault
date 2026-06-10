#!/bin/bash
# DreamVault 卸载脚本
#
# 用途：完全移除 launchd job +（可选）删除 vault 数据
#
# 用法：
#   bash scripts/uninstall.sh                 # 只卸 job，保留 vault 数据
#   bash scripts/uninstall.sh --purge         # 卸 job + 删 ~/.dreamvault
#   bash scripts/uninstall.sh --purge --vault ~/MyVault

set -e

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VAULT="${HOME}/.dreamvault"
PURGE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --vault) VAULT="$2"; shift 2 ;;
        --purge) PURGE=true; shift ;;
        *) echo "未知参数: $1"; exit 1 ;;
    esac
done

UID_VAL=$(id -u)
PLIST_TARGET="$HOME/Library/LaunchAgents/com.OmixNet.dreamvault.dream.plist"

# —— 1. 停 + 卸 job ——
echo "==> [1/3] Stopping + unloading launchd job..."
launchctl bootout "gui/$UID_VAL" "$PLIST_TARGET" 2>/dev/null || echo "    (job 未运行，跳过)"
launchctl bootout "gui/$UID_VAL" "$PLIST_TARGET" 2>/dev/null || true
echo "    OK: unloaded"

# —— 2. 删 plist + wrapper ——
echo "==> [2/3] Removing plist + wrapper from ~/Library/LaunchAgents/..."
rm -f "$PLIST_TARGET"
rm -f "$HOME/Library/LaunchAgents/dream-runner.sh"
echo "    OK: removed"

# —— 3. 可选：删 vault 数据 ——
if [ "$PURGE" = true ]; then
    echo "==> [3/3] Purging vault at $VAULT..."
    if [ -d "$VAULT" ]; then
        rm -rf "$VAULT"
        echo "    OK: deleted"
    else
        echo "    目录不存在，跳过"
    fi
else
    echo "==> [3/3] Skipping vault purge (pass --purge to delete $VAULT)"
fi

echo
echo "==> 完成。"
echo "    重装：bash $REPO/scripts/install.sh"

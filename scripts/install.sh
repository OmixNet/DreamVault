#!/bin/bash
# DreamVault 首次安装脚本
#
# 用途：全新机器上一键把 DreamVault 装好
#   1. build release 版 dream 二进制
#   2. 创建 ~/.dreamvault（git 仓库 + raw/ 子目录 + .dream/）
#   3. 装 launchd plist + wrapper 到 ~/Library/LaunchAgents/
#   4. bootstrap 加载 plist
#
# 用法：
#   bash scripts/install.sh
# 或带参数：
#   bash scripts/install.sh --vault ~/MyVault

set -e

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VAULT="${HOME}/.dreamvault"

# 解析参数
while [[ $# -gt 0 ]]; do
    case "$1" in
        --vault) VAULT="$2"; shift 2 ;;
        *) echo "未知参数: $1"; exit 1 ;;
    esac
done

echo "==> REPO: $REPO"
echo "==> VAULT: $VAULT"

# —— 1. Build ——
echo "==> [1/5] Building release dream..."
XCTOOL=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin
export PATH="$XCTOOL:$PATH"
(cd "$REPO" && /usr/bin/swift build --package-path "$REPO" -c release)
echo "    OK: $REPO/.build/release/dream"

# —— 2. 创建 vault 目录 + git 仓库 + raw/ ——
echo "==> [2/5] Initializing vault at $VAULT..."
mkdir -p "$VAULT/raw"
mkdir -p "$VAULT/.dream"

# git init（事务边界前提）
if [ ! -d "$VAULT/.git" ]; then
    (cd "$VAULT" && git init -b main)
    # 初始 commit 避免 root commit 边界
    echo "# DreamVault" > "$VAULT/README.md"
    (cd "$VAULT" && git add README.md && git -c user.name=DreamVault -c user.email=dream@dreamvault.local commit -m "init dream vault")
    echo "    OK: git init + initial commit"
else
    echo "    已是 git 仓库，跳过"
fi

# —— 3. 装 plist + wrapper ——
echo "==> [3/5] Installing plist + wrapper to ~/Library/LaunchAgents/..."
mkdir -p "$HOME/Library/Logs/DreamVault"
mkdir -p "$HOME/Library/LaunchAgents"

# 修改 plist 的 DREAMVAULT_VAULT 为本机实际值
PLIST_TARGET="$HOME/Library/LaunchAgents/com.OmixNet.dreamvault.dream.plist"
sed "s|<string>/Users/biomatrix/.dreamvault</string>|<string>$VAULT</string>|g" \
    "$REPO/launchd/com.OmixNet.dreamvault.dream.plist" > "$PLIST_TARGET"
echo "    OK: $PLIST_TARGET"

# wrapper
cp "$REPO/launchd/dream-runner.sh" "$HOME/Library/LaunchAgents/dream-runner.sh"
chmod +x "$HOME/Library/LaunchAgents/dream-runner.sh"
echo "    OK: $HOME/Library/LaunchAgents/dream-runner.sh"

# —— 4. Bootstrap plist ——
echo "==> [4/5] Bootstrapping launchd job..."
UID_VAL=$(id -u)
# 先 bootout（容忍失败：可能没装过）
launchctl bootout "gui/$UID_VAL" "$PLIST_TARGET" 2>/dev/null || true
# bootstrap
launchctl bootstrap "gui/$UID_VAL" "$PLIST_TARGET"
echo "    OK: bootstrapped"

# —— 5. 立即触发一次（看 RunAtLoad 跑得对不对） ——
echo "==> [5/5] Triggering immediate run (RunAtLoad)..."
launchctl kickstart -k "gui/$UID_VAL/com.OmixNet.dreamvault.dream"
echo "    触发了，等几秒后查日志："
echo "    tail -f $HOME/Library/Logs/DreamVault/dream.out.log"
echo
echo "==> 完成！"
echo "    - launchctl list | grep dreamvault     # 查 job 状态"
echo "    - launchctl print gui/$UID_VAL/com.OmixNet.dreamvault.dream | head  # 详情"
echo "    - tail -50 $HOME/Library/Logs/DreamVault/dream.out.log   # 日志"

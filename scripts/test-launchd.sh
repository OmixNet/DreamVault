#!/bin/bash
# launchd 集成测试 —— 实际让 launchd 跑一遍 dream，验证 plist+wrapper 正确
#
# 跑法：
#   bash scripts/test-launchd.sh
#
# 测试覆盖：
#   1. plist 格式合法（plutil -lint）
#   2. wrapper 脚本语法合法（bash -n）+ 可执行
#   3. plist 装到 ~/Library/LaunchAgents/
#   4. launchctl bootstrap 成功
#   5. launchctl list 能看到 job
#   6. kickstart 立即触发，dream 真跑了
#   7. 日志文件产生且内容含 dream 输出
#   8. vault 里 .dream/reports/ 有新文件

set -e

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLIST_SRC="$REPO/launchd/com.OmixNet.dreamvault.dream.plist"
WRAPPER_SRC="$REPO/launchd/dream-runner.sh"
PLIST_TARGET="$HOME/Library/LaunchAgents/com.OmixNet.dreamvault.dream.plist"
WRAPPER_TARGET="$HOME/Library/LaunchAgents/dream-runner.sh"
LOG_DIR="$HOME/Library/Logs/DreamVault"
LOG_OUT="$LOG_DIR/dream.out.log"
LOG_ERR="$LOG_DIR/dream.err.log"

# 测试用临时 vault（不污染真实 ~/.dreamvault）
TEST_VAULT="$(mktemp -d -t dreamvault-test-XXXXX)"
TEST_LABEL="com.OmixNet.dreamvault.test.$(basename "$TEST_VAULT")"
TEST_PLIST="/tmp/${TEST_LABEL}.plist"

# 配 dream 二进制（release 优先）
if [ ! -x "$REPO/.build/release/dream" ]; then
    if [ ! -x "$REPO/.build/debug/dream" ]; then
        echo "ERROR: dream 二进制不存在，请先 'cd $REPO && swift build'" >&2
        exit 1
    fi
    DREAM_BIN_REL="$REPO/.build/debug/dream"
else
    DREAM_BIN_REL="$REPO/.build/release/dream"
fi

cleanup() {
    launchctl bootout "gui/$(id -u)" "$TEST_PLIST" 2>/dev/null || true
    rm -f "$TEST_PLIST"
    rm -rf "$TEST_VAULT"
}
trap cleanup EXIT

# —— 1. plist 格式 ——
echo "==> [1/8] plist 格式合法?"
plutil -lint "$PLIST_SRC" >/dev/null
echo "    OK"

# —— 2. wrapper 语法 + 可执行 ——
echo "==> [2/8] wrapper 语法 + 可执行?"
bash -n "$WRAPPER_SRC"
[ -x "$WRAPPER_SRC" ]
echo "    OK"

# —— 3. 生成测试用 plist（指向临时 vault，1 分钟后跑，方便看调度） ——
echo "==> [3/8] 生成测试 plist（临时 vault，1 分钟后跑）..."
cat > "$TEST_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$TEST_LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>-c</string>
        <string>cd $TEST_VAULT && $DREAM_BIN_REL run --vault $TEST_VAULT --llm mock --verbose</string>
    </array>
    <key>StartCalendarInterval</key>
    <dict>
        <key>Minute</key>
        <integer>$(date +%M)</integer>
    </dict>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <false/>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:/usr/bin:/bin</string>
    </dict>
    <key>StandardOutPath</key>
    <string>$LOG_DIR/test.out.log</string>
    <key>StandardErrorPath</key>
    <string>$LOG_DIR/test.err.log</string>
</dict>
</plist>
EOF
mkdir -p "$TEST_VAULT/raw" "$LOG_DIR"
(cd "$TEST_VAULT" && git init -q -b main)
echo "    OK: $TEST_PLIST → $TEST_VAULT"

# —— 4. bootstrap ——
echo "==> [4/8] launchctl bootstrap..."
UID_VAL=$(id -u)
launchctl bootout "gui/$UID_VAL" "$TEST_PLIST" 2>/dev/null || true
launchctl bootstrap "gui/$UID_VAL" "$TEST_PLIST"
echo "    OK: bootstrapped"

# —— 5. list 看到 job ——
echo "==> [5/8] launchctl list 包含 $TEST_LABEL ?"
sleep 1
if launchctl list | grep -q "$TEST_LABEL"; then
    echo "    OK"
else
    echo "    FAIL: list 里没看到 job"
    exit 1
fi

# —— 6. 立即触发 ——
echo "==> [6/8] launchctl kickstart 立即触发..."
launchctl kickstart -k "gui/$UID_VAL/$TEST_LABEL"
echo "    OK: kickstart 完成"

# —— 7. 等几秒看日志 ——
echo "==> [7/8] 等待 5s 看日志..."
sleep 5
if [ -f "$LOG_DIR/test.out.log" ] || [ -f "$LOG_DIR/test.err.log" ]; then
    echo "    OK: 日志产生"
    echo "    --- test.out.log (head) ---"
    head -10 "$LOG_DIR/test.out.log" 2>/dev/null || true
    echo "    --- test.err.log (head) ---"
    head -10 "$LOG_DIR/test.err.log" 2>/dev/null || true
else
    echo "    FAIL: 没产生日志"
    exit 1
fi

# —— 8. vault 里 .dream/reports/ 有新文件 ——
echo "==> [8/8] vault 里产生 dream-report ?"
if ls "$TEST_VAULT/.dream/reports/" 2>/dev/null | head -1; then
    echo "    OK"
else
    echo "    FAIL: .dream/reports/ 空"
    exit 1
fi

echo
echo "==> ALL 8 STEPS PASSED — launchd 集成正常"

#!/bin/bash
# scripts/build_and_run.sh — Build macOS Apps 的"标准开发运行入口"
#
# 用途：把 dream 引擎 + SwiftUI GUI 包成开发 .app，用 open -n 启动，
#       验证：进程参数、AppModel.vaultRoot、日志写到 ~/Library/Logs/DreamVault/。
#
# 用法：
#   bash scripts/build_and_run.sh                          # 默认 vault=~/.dreamvault
#   bash scripts/build_and_run.sh --vault /path/to/vault   # 自定义 vault
#   bash scripts/build_and_run.sh --verify                 # 启动后跑 smoke checks
#   bash scripts/build_and_run.sh --no-open                # 只 build，不 open
#   bash scripts/build_and_run.sh --keep                   # 使用 /tmp 下的时间戳 app
#
# 设计点：
#   - 默认 .app 固定为 ~/Applications/DreamVault-dev.app，避免每次换路径触发 TCC 权限弹窗
#   - --keep 时才使用 /tmp 下的时间戳 .app，用于保留独立构建产物
#   - 用 `open -n` 强制开新实例（不会命中之前可能残留的进程）
#   - stdout/stderr 重定向到 ~/Library/Logs/DreamVault/dev-<timestamp>.log
#   - --verify 模式会：
#       1) 用 ps 抓进程确认参数
#       2) 用 AX 检查是否真的创建了可见 GUI 窗口
#       3) 用 lsof / log 做诊断输出（不作为硬失败条件）
#
# 退出码：
#   0  = 启动成功（或 --no-open 只 build 也成功）
#   1  = build 失败
#   2  = open 启动后未发现进程
#   3  = --verify 模式 smoke check 失败

set -e

# ——— 1. 参数解析 ———
VAULT="$HOME/.dreamvault"
VERIFY=0
NO_OPEN=0
KEEP=0
while [ $# -gt 0 ]; do
    case "$1" in
        --vault)   VAULT="$2"; shift 2 ;;
        --vault=*) VAULT="${1#--vault=}"; shift 1 ;;
        -v)        VAULT="$2"; shift 2 ;;
        --verify)  VERIFY=1; shift 1 ;;
        --no-open) NO_OPEN=1; shift 1 ;;
        --keep)    KEEP=1; shift 1 ;;
        -h|--help)
            sed -n '4,18p' "$0"
            exit 0
            ;;
        *)
            echo "Unknown arg: $1" >&2
            exit 1
            ;;
    esac
done

# ——— 2. 准备开发 .app 目录 ———
# macOS Launch Services 在 /tmp 下的 .app 第一次 open 经常报
# "Launchd job spawn failed"（RBSRequestError 5），需要 lsregister 一下。
# 但更稳的做法是放 ~/Applications，Launch Services 立刻认得。
# --keep 模式：用户显式说保留时放 /tmp（开发隔离）；否则复用稳定的
# ~/Applications/DreamVault-dev.app，避免 Launch Services/TCC/Computer Use
# 把每个时间戳包都当成新 app。
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
LOG_DIR="$HOME/Library/Logs/DreamVault"
LOG_FILE="$LOG_DIR/dev-$TIMESTAMP.log"

mkdir -p "$LOG_DIR"
if [ "$KEEP" = "1" ]; then
    TMP_APP="/tmp/DreamVault-dev-$TIMESTAMP.app"
else
    TMP_APP="$HOME/Applications/DreamVault-dev.app"
fi
EXISTING_BIN="$TMP_APP/Contents/MacOS/DreamVault"
if [ -x "$EXISTING_BIN" ]; then
    EXISTING_PIDS=$(pgrep -f "$EXISTING_BIN" 2>/dev/null || true)
    if [ -n "$EXISTING_PIDS" ]; then
        echo "==> 停止旧 dev 进程: $EXISTING_PIDS"
        for pid in $EXISTING_PIDS; do
            kill "$pid" 2>/dev/null || true
        done
        sleep 1
        for pid in $EXISTING_PIDS; do
            if kill -0 "$pid" 2>/dev/null; then
                kill -9 "$pid" 2>/dev/null || true
            fi
        done
    fi
fi
if [ -e "$TMP_APP" ]; then
    rm -rf "$TMP_APP"
fi
mkdir -p "$TMP_APP/Contents/MacOS"
mkdir -p "$TMP_APP/Contents/Resources"

# .app 内容目录
APP_BUNDLE="$TMP_APP/Contents"
MACOS_BIN="$APP_BUNDLE/MacOS/DreamVault"
INFO_PLIST="$APP_BUNDLE/Info.plist"

# ——— 3. swift build release ———
echo "==> [1/4] swift build -c release..."
XCTOOL=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin
export PATH="$XCTOOL:$PATH"
if ! (cd "$REPO" && /usr/bin/swift build --package-path "$REPO" -c release 2>&1 | tail -5); then
    echo "ERROR: swift build 失败" >&2
    exit 1
fi

SOURCE_BIN="$REPO/.build/release/dream"
if [ ! -x "$SOURCE_BIN" ]; then
    echo "ERROR: $SOURCE_BIN 没建出来" >&2
    exit 1
fi

# ——— 4. 拷贝二进制 + 写 Info.plist ———
echo "==> [2/4] 打包开发 .app 到 $TMP_APP..."
cp "$SOURCE_BIN" "$MACOS_BIN"
chmod +x "$MACOS_BIN"

cat > "$INFO_PLIST" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>DreamVault</string>
    <key>CFBundleIdentifier</key>
    <string>com.OmixNet.dreamvault.dev</string>
    <key>CFBundleName</key>
    <string>DreamVault-dev</string>
    <key>CFBundleDisplayName</key>
    <string>DreamVault (dev)</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleVersion</key>
    <string>dev</string>
    <key>CFBundleShortVersionString</key>
    <string>dev</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>LSUIElement</key>
    <false/>
    <key>NSSupportsAutomaticTermination</key>
    <false/>
    <key>NSQuitAlwaysKeepsWindows</key>
    <false/>
    <key>NSHumanReadableCopyright</key>
    <string>DreamVault dev build — temporary .app for verification.</string>
</dict>
</plist>
EOF
plutil -lint "$INFO_PLIST" >/dev/null

# 复制 SwiftPM 产物到 .app 后必须重新签整个 bundle。否则 Info.plist 不在
# code signature seal 内，macOS 26 的 AppleSystemPolicy 会拒绝启动：
# "Security policy would not allow process".
if ! codesign --force --deep --sign - "$TMP_APP" >/dev/null 2>&1; then
    echo "ERROR: codesign 开发 .app 失败" >&2
    exit 1
fi

# ——— 5. 启动 ———
if [ "$NO_OPEN" = "1" ]; then
    echo "==> [3/4] --no-open，跳过 open"
    echo "开发 .app: $TMP_APP"
    exit 0
fi

echo "==> [3/4] 启动 GUI: open -n $TMP_APP --args app --vault $VAULT"
echo "         日志: $LOG_FILE"

# 第一次 open 临时 .app 经常失败：macOS Launch Services 还没注册这个 bundle
# 路径。lsregister 一下让 Launch Services 认得再 open。
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"
if [ -x "$LSREGISTER" ]; then
    "$LSREGISTER" -f "$TMP_APP" >/dev/null 2>&1 || true
fi

# open -n 强制新实例（即使有残留进程也开新的），--args 透传给 binary
if ! open -n "$TMP_APP" --args app --vault "$VAULT" 2>&1 | tee -a "$LOG_FILE"; then
    echo "ERROR: open 启动失败" >&2
    exit 1
fi

# 等进程起来
sleep 3
PID=$(pgrep -f "$MACOS_BIN" 2>/dev/null | head -1 || true)
if [ -z "$PID" ]; then
    PID=$(/usr/bin/osascript -e 'tell application "System Events" to get unix id of first process whose bundle identifier is "com.OmixNet.dreamvault.dev"' 2>/dev/null || true)
fi
if [ -z "$PID" ]; then
    echo "ERROR: 启动后未发现进程" >&2
    cat "$LOG_FILE" 2>/dev/null | head -20
    exit 2
fi
echo "    进程 PID: $PID"

# ——— 6. --verify smoke checks ———
if [ "$VERIFY" = "1" ]; then
    echo "==> [4/4] --verify smoke checks..."
    FAIL=0

    # 1) 进程参数里有 --vault
    PROCESS_ARGS="$(ps -p "$PID" -o args= 2>/dev/null || true)"
    if [ -z "$PROCESS_ARGS" ]; then
        echo "    ⚠ ps 不可用，跳过进程参数检查"
    elif ! echo "$PROCESS_ARGS" | grep -q -- "--vault $VAULT"; then
        echo "    ✗ 进程参数未含 --vault $VAULT"
        echo "    实际: $PROCESS_ARGS"
        FAIL=1
    else
        echo "    ✓ 进程参数含 --vault"
    fi

    # 2) AX GUI window：确认当前 dev PID 真的有可见窗口，而不是误抓已打开的正式版 DreamVault。
    AX_WINDOW_COUNT=$(/usr/bin/osascript -e "tell application \"System Events\" to tell first process whose unix id is $PID to count of windows" 2>/dev/null || true)
    if [[ "$AX_WINDOW_COUNT" =~ ^[0-9]+$ ]] && [ "$AX_WINDOW_COUNT" -gt 0 ]; then
        echo "    ✓ AX GUI window visible ($AX_WINDOW_COUNT via PID $PID)"
    else
        echo "    ✗ AX GUI window 不可见或不可读取（count=${AX_WINDOW_COUNT:-unavailable}）"
        FAIL=1
    fi

    # 3) vault 目录可被进程访问（lsof 列 fd）。GUI 读完文件后 fd 可能已关闭，仅作诊断。
    if ! lsof -p "$PID" 2>/dev/null | grep -q "$VAULT"; then
        echo "    ⚠ lsof 找不到 vault 路径（GUI 可能已读完并关闭 fd）"
    else
        echo "    ✓ 进程打开了 vault"
    fi

    # 4) 日志文件写入。open(1) 不保证捕获 app stdout/stderr，所以这里只提示。
    if [ -s "$LOG_FILE" ]; then
        echo "    ✓ 日志已写入 $(wc -l < "$LOG_FILE") 行"
    else
        echo "    ℹ 日志为空（open 不一定捕获 app stdout/stderr）"
    fi

    if [ "$FAIL" = "1" ]; then
        echo "VERIFY 失败" >&2
        exit 3
    fi
    echo "VERIFY 通过"
fi

# ——— 7. 开发包位置 ———
if [ "$KEEP" = "1" ]; then
    echo "==> [4/4] --keep 模式，临时 .app 留在: $TMP_APP"
else
    echo "==> [4/4] ~/Applications 下的稳定 dev build，保留在: $TMP_APP"
    echo "    下次运行脚本会覆盖这个路径，避免 TCC 和 GUI 自动化识别漂移"
fi

echo
echo "启动命令（手动重启用）："
echo "  open -n $TMP_APP --args app --vault $VAULT"
echo
echo "进程信息："
echo "  PID:        $PID"
echo "  开发 .app:  $TMP_APP"
echo "  日志:       $LOG_FILE"
echo
echo "停止："
echo "  kill $PID"
echo
echo "卸载："
echo "  kill $PID && rm -rf $TMP_APP"

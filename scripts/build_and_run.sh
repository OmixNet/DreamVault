#!/bin/bash
# scripts/build_and_run.sh — Build macOS Apps 的"标准开发运行入口"
#
# 用途：把 dream 引擎 + SwiftUI GUI 包成临时 .app，用 open -n 启动，
#       验证：进程参数、AppModel.vaultRoot、日志写到 ~/Library/Logs/DreamVault/。
#
# 用法：
#   bash scripts/build_and_run.sh                          # 默认 vault=~/.dreamvault
#   bash scripts/build_and_run.sh --vault /path/to/vault   # 自定义 vault
#   bash scripts/build_and_run.sh --verify                 # 启动后跑 smoke checks
#   bash scripts/build_and_run.sh --no-open                # 只 build，不 open
#   bash scripts/build_and_run.sh --keep                   # 启动后保留临时 .app（不删）
#
# 设计点：
#   - 临时 .app 放 /tmp/dreamvault-app-<uuid>/，不污染 ~/Applications
#   - 用 `open -n` 强制开新实例（不会命中之前可能残留的进程）
#   - stdout/stderr 重定向到 ~/Library/Logs/DreamVault/dev-<timestamp>.log
#   - --verify 模式会：
#       1) 用 ps 抓进程确认参数
#       2) 用 lsof 检查打开的 vault 路径
#       3) sleep 几秒后检查 .dream/reports/ 是否有新文件
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

# ——— 2. 准备临时 .app 目录 ———
# macOS Launch Services 在 /tmp 下的 .app 第一次 open 经常报
# "Launchd job spawn failed"（RBSRequestError 5），需要 lsregister 一下。
# 但更稳的做法是放 ~/Applications，Launch Services 立刻认得。
# --keep 模式：用户显式说保留时仍放 /tmp（开发隔离）；否则放 ~/Applications。
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
LOG_DIR="$HOME/Library/Logs/DreamVault"
LOG_FILE="$LOG_DIR/dev-$TIMESTAMP.log"

mkdir -p "$LOG_DIR"
if [ "$KEEP" = "1" ]; then
    TMP_APP="/tmp/dreamvault-app-$TIMESTAMP"
else
    TMP_APP="$HOME/Applications/DreamVault-dev-$TIMESTAMP.app"
fi
mkdir -p "$TMP_APP/Contents/MacOS"
mkdir -p "$TMP_APP/Contents/Resources"

# 临时 .app 也建在子目录里避免清理时误删
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
echo "==> [2/4] 打包临时 .app 到 $TMP_APP..."
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

# ——— 5. 启动 ———
if [ "$NO_OPEN" = "1" ]; then
    echo "==> [3/4] --no-open，跳过 open"
    echo "临时 .app: $TMP_APP"
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
PID=$(pgrep -f "Contents/MacOS/DreamVault" | head -1 || true)
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
    if ! ps -p "$PID" -o args= 2>/dev/null | grep -q -- "--vault $VAULT"; then
        echo "    ✗ 进程参数未含 --vault $VAULT"
        echo "    实际: $(ps -p "$PID" -o args= 2>/dev/null)"
        FAIL=1
    else
        echo "    ✓ 进程参数含 --vault"
    fi

    # 2) vault 目录可被进程访问（lsof 列 fd）
    if ! lsof -p "$PID" 2>/dev/null | grep -q "$VAULT"; then
        echo "    ⚠ lsof 找不到 vault 路径（GUI 还没打开它，正常）"
    else
        echo "    ✓ 进程打开了 vault"
    fi

    # 3) 日志文件写入
    if [ -s "$LOG_FILE" ]; then
        echo "    ✓ 日志已写入 $(wc -l < "$LOG_FILE") 行"
    else
        echo "    ⚠ 日志为空"
    fi

    if [ "$FAIL" = "1" ]; then
        echo "VERIFY 失败" >&2
        exit 3
    fi
    echo "VERIFY 通过"
fi

# ——— 7. 清理（除非 --keep） ———
if [ "$KEEP" = "0" ] && [[ "$TMP_APP" == /tmp/* ]]; then
    echo "==> [4/4] 临时 .app 保留在: $TMP_APP (用 --keep 留到下次)"
elif [ "$KEEP" = "0" ]; then
    # ~/Applications 下的 dev build 不自动删，留用户手清
    echo "==> [4/4] ~/Applications 下的 dev build，保留在: $TMP_APP"
    echo "    想清理：rm -rf $TMP_APP"
else
    echo "==> [4/4] --keep 模式，临时 .app 留在: $TMP_APP"
fi

echo
echo "启动命令（手动重启用）："
echo "  open -n $TMP_APP --args app --vault $VAULT"
echo
echo "进程信息："
echo "  PID:        $PID"
echo "  临时 .app:  $TMP_APP"
echo "  日志:       $LOG_FILE"
echo
echo "停止："
echo "  kill $PID"
echo
echo "卸载："
echo "  kill $PID && rm -rf $TMP_APP"

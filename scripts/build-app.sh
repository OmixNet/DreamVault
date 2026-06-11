#!/bin/bash
# 把 dream 二进制包成 macOS .app bundle
#
# 用途：SwiftUI 外壳需要一个 .app bundle 才能用 'open' 启动（launchd 不能启动 GUI）。
#       本脚本生成 ~/Applications/DreamVault.app（如果该目录不存在则创建）
#
# 跑法：
#   bash scripts/build-app.sh
#   open ~/Applications/DreamVault.app           # 启动 GUI
#
# 卸载：
#   rm -rf ~/Applications/DreamVault.app

set -e

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$HOME/Applications/DreamVault.app"
CONTENTS="$APP_DIR/Contents"
MACOS="$CONTENTS/MacOS"
SOURCE_BIN="$REPO/.build/release/dream"

# —— 1. Build release ——（先）
echo "==> [1/4] swift build -c release..."
XCTOOL=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin
export PATH="$XCTOOL:$PATH"
(cd "$REPO" && /usr/bin/swift build --package-path "$REPO" -c release)
if [ ! -x "$SOURCE_BIN" ]; then
    echo "ERROR: $SOURCE_BIN 没建出来" >&2
    exit 1
fi
echo "    OK: $SOURCE_BIN"

# —— 2. 建 .app 目录结构 ——
echo "==> [2/4] Creating .app bundle at $APP_DIR..."
mkdir -p "$HOME/Applications"
/Users/biomatrix/.mavis/bin/mavis-trash "$APP_DIR" '2>/dev/null' || true
mkdir -p "$MACOS"
cp "$SOURCE_BIN" "$MACOS/DreamVault"
chmod +x "$MACOS/DreamVault"

# —— 3. 写 Info.plist ——
echo "==> [3/4] Writing Info.plist..."
cat > "$CONTENTS/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>DreamVault</string>
    <key>CFBundleIdentifier</key>
    <string>com.OmixNet.dreamvault.gui</string>
    <key>CFBundleName</key>
    <string>DreamVault</string>
    <key>CFBundleDisplayName</key>
    <string>DreamVault</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleVersion</key>
    <string>0.1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>LSUIElement</key>
    <false/>
    <!-- 禁用自动窗口状态恢复（SwiftUI WindowGroup + 我们没存状态，否则启动空窗） -->
    <key>NSSupportsAutomaticTermination</key>
    <false/>
    <key>NSQuitAlwaysKeepsWindows</key>
    <false/>
    <key>NSHumanReadableCopyright</key>
    <string>DreamVault GUI — local-first knowledge base + nightly dream.</string>
</dict>
</plist>
EOF
plutil -lint "$CONTENTS/Info.plist" >/dev/null
echo "    OK"

# —— 4. 验证 + 打印启动命令 ——
echo "==> [4/4] 验证 .app..."
ls -la "$MACOS/DreamVault" >/dev/null
plutil -p "$CONTENTS/Info.plist" | head -3
echo
echo "==> 完成！"
echo
echo "启动 GUI："
echo "  open -n ~/Applications/DreamVault.app"
echo
echo "或带 vault 路径："
echo "  open -n ~/Applications/DreamVault.app --args app --vault ~/MyVault"
echo
echo "或开发用（自动 build + 临时 .app + verify）："
echo "  bash scripts/build_and_run.sh --verify"
echo
echo "卸载："
echo "  rm -rf ~/Applications/DreamVault.app"

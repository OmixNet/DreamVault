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
#
# 代码签名（P1-B）：
#   如果 keychain 里有 codesign identity，脚本会问用哪个：
#     - 自签名 cert (DreamVault Developer) → 给身边人 + 第一次 Gatekeeper 拦
#     - Apple Developer ID (有的话) → 公证后 Gatekeeper 不拦
#   跳过签名：DREAMVAULT_SKIP_SIGN=1 bash scripts/build-app.sh
#   指定 identity：DREAMVAULT_SIGN_IDENTITY="<name>" bash scripts/build-app.sh

set -e

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$HOME/Applications/DreamVault.app"
CONTENTS="$APP_DIR/Contents"
MACOS="$CONTENTS/MacOS"
SOURCE_BIN="$REPO/.build/release/dream"
BUNDLE_VERSION="0.2.1"

# —— 1. Build release ——（先）
echo "==> [1/5] swift build -c release..."
XCTOOL=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin
export PATH="$XCTOOL:$PATH"
(cd "$REPO" && /usr/bin/swift build --package-path "$REPO" -c release)
if [ ! -x "$SOURCE_BIN" ]; then
    echo "ERROR: $SOURCE_BIN 没建出来" >&2
    exit 1
fi
echo "    OK: $SOURCE_BIN"

# —— 2. 建 .app 目录结构 ——
echo "==> [2/5] Creating .app bundle at $APP_DIR..."
mkdir -p "$HOME/Applications"
/Users/biomatrix/.mavis/bin/mavis-trash "$APP_DIR" '2>/dev/null' || true
mkdir -p "$MACOS"
cp "$SOURCE_BIN" "$MACOS/DreamVault"
chmod +x "$MACOS/DreamVault"

# —— 3. 写 Info.plist ——
echo "==> [3/5] Writing Info.plist..."
cat > "$CONTENTS/Info.plist" <<EOF
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
    <string>${BUNDLE_VERSION}</string>
    <key>CFBundleShortVersionString</key>
    <string>${BUNDLE_VERSION}</string>
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

# —— 4. Code sign（hardened runtime） ——
echo "==> [4/5] Code signing..."
SIGN_IDENTITY="${DREAMVAULT_SIGN_IDENTITY:-}"

if [ -n "$DREAMVAULT_SKIP_SIGN" ]; then
    echo "    SKIPPED (DREAMVAULT_SKIP_SIGN=1)"
elif [ -z "$SIGN_IDENTITY" ]; then
    # 自动发现：找 keychain 里第一个 codesign identity
    AVAILABLE=$(security find-identity -p codesigning 2>/dev/null | grep -v "matching" | grep -v "^$" | head -3)
    if [ -z "$AVAILABLE" ]; then
        echo "    WARNING: keychain 里没有 codesign identity，跳过签名"
        echo "    (运行 'bash scripts/create-self-signed-cert.sh' 生成自签名 cert)"
    else
        FIRST=$(echo "$AVAILABLE" | head -1 | awk -F'"' '{print $2}')
        echo "    发现 codesign identity: $FIRST"
        if [ -t 1 ]; then
            read -p "    用这个签名? [Y/n] " YN
            if [ -z "$YN" ] || [ "$YN" = "y" ] || [ "$YN" = "Y" ]; then
                SIGN_IDENTITY="$FIRST"
            else
                echo "    跳过签名（用 DREAMVAULT_SIGN_IDENTITY=\"<name>\" 指定别的）"
            fi
        else
            # 非交互模式（CI/脚本调用）：直接用第一个
            SIGN_IDENTITY="$FIRST"
        fi
    fi
fi

if [ -n "$SIGN_IDENTITY" ]; then
    echo "    签名: --options=runtime --sign '$SIGN_IDENTITY' ..."
    # --force 覆盖之前的任何 ad-hoc 签名
    # --options=runtime 启用 hardened runtime
    # --deep 递归签名 nested bundles（虽然我们没有）
    codesign --force --deep --options=runtime --sign "$SIGN_IDENTITY" "$APP_DIR" 2>&1
    echo "    验证签名:"
    codesign -dv "$APP_DIR" 2>&1 | head -5 | sed 's/^/      /'
    echo "    spctl 评估:"
    spctl --assess --type execute -vv "$APP_DIR" 2>&1 | head -3 | sed 's/^/      /' || true
else
    echo "    未签名（ad-hoc 启动可能 Gatekeeper 拦截）"
fi

# —— 5. 验证 + 打印启动命令 ——
echo "==> [5/5] 验证 .app..."
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
echo "打 DMG 分发："
echo "  bash scripts/build-dmg.sh"
echo
echo "卸载："
echo "  rm -rf ~/Applications/DreamVault.app"

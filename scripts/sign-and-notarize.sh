#!/bin/bash
# P6-T1: 升级到 Apple Developer ID 签名的 4 步脚本。
#
# 前置：你已经从 Apple Developer Program 拿到 Developer ID Application cert
# 导入到本机 keychain（Xcode → Settings → Accounts → Manage Certificates → +）
#
# 用法：
#   # 1. 你需要先创建一个 "keychain profile"（notarytool 用来存 Apple ID 凭据）
#   xcrun notarytool store-credentials --apple-id "you@example.com" \
#       --team-id "ABCDE12345" --password "abcd-efgh-ijkl-mnop"
#   # 默认 profile 名 "AC_PASSWORD"；可以用 --profile <name> 改
#
#   # 2. 跑这个脚本
#   DREAMVAULT_NOTARY_PROFILE="AC_PASSWORD" \
#   DREAMVAULT_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
#   bash scripts/sign-and-notarize.sh
#
#   # 3. 给身边人的 .dmg → ~/Desktop/DreamVault-<version>.dmg（已签 + 公证 + staple）
#
# 流程（macOS 13+）：
#   1. swift build -c release
#   2. 打包 .app
#   3. codesign --options=runtime --timestamp --sign "$identity"  ← hardened runtime + secure timestamp
#   4. ditto -c -k --sequesterRsrc --keepParent .app DreamVault.zip  ← notarytool 要 .zip
#   5. xcrun notarytool submit + wait + staple
#   6. 验 spctl：spctl --assess 应返回 accepted（不再 override）
#   7. 打 DMG

set -e

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$HOME/Applications/DreamVault.app"
CONTENTS="$APP_DIR/Contents"
MACOS="$CONTENTS/MacOS"
BUNDLE_VERSION="${DREAMVAULT_VERSION:-0.3.0}"
NOTARY_PROFILE="${DREAMVAULT_NOTARY_PROFILE:-AC_PASSWORD}"
SIGN_IDENTITY="${DREAMVAULT_SIGN_IDENTITY:?ERROR: DREAMVAULT_SIGN_IDENTITY required}"

# —— 1. Build release ——
echo "==> [1/7] swift build -c release..."
XCTOOL=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin
export PATH="$XCTOOL:$PATH"
(cd "$REPO" && /usr/bin/swift build --package-path "$REPO" -c release)
SOURCE_BIN="$REPO/.build/release/dream"
[ -x "$SOURCE_BIN" ] || { echo "ERROR: build failed" >&2; exit 1; }
echo "    OK: $SOURCE_BIN"

# —— 2. 打包 .app ——
echo "==> [2/7] Packaging .app at $APP_DIR..."
mkdir -p "$HOME/Applications"
/Users/biomatrix/.mavis/bin/mavis-trash "$APP_DIR" '2>/dev/null' || true
mkdir -p "$MACOS"
cp "$SOURCE_BIN" "$MACOS/DreamVault"
chmod +x "$MACOS/DreamVault"
# AppIcon
if [ -f "$REPO/Resources/AppIcon.icns" ]; then
    mkdir -p "$CONTENTS/Resources"
    cp "$REPO/Resources/AppIcon.icns" "$CONTENTS/Resources/AppIcon.icns"
fi
# Info.plist
cat > "$CONTENTS/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>DreamVault</string>
    <key>CFBundleIdentifier</key><string>com.OmixNet.dreamvault.gui</string>
    <key>CFBundleName</key><string>DreamVault</string>
    <key>CFBundleDisplayName</key><string>DreamVault</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleVersion</key><string>${BUNDLE_VERSION}</string>
    <key>CFBundleShortVersionString</key><string>${BUNDLE_VERSION}</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIconName</key><string>AppIcon</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>LSUIElement</key><false/>
    <key>NSSupportsAutomaticTermination</key><false/>
    <key>NSQuitAlwaysKeepsWindows</key><false/>
    <key>NSHumanReadableCopyright</key><string>DreamVault GUI — local-first knowledge base + nightly dream.</string>
</dict>
</plist>
EOF
plutil -lint "$CONTENTS/Info.plist" >/dev/null

# —— 3. 签名（hardened runtime + secure timestamp）——
echo "==> [3/7] Code signing with Developer ID..."
codesign --force --deep --options=runtime --timestamp --sign "$SIGN_IDENTITY" "$APP_DIR"
echo "    签名完成"

# —— 4. 验证签名 ——
echo "==> [4/7] Verify signature..."
codesign -dv "$APP_DIR" 2>&1 | head -6
spctl --assess --type execute -vv "$APP_DIR" 2>&1

# —— 5. ditto 打包成 zip 给 notarytool ——
echo "==> [5/7] Packing zip for notarytool..."
ZIP_PATH="/tmp/dv-zip-$$"
mkdir -p "$ZIP_PATH"
cp -R "$APP_DIR" "$ZIP_PATH/DreamVault.app"
ditto -c -k --sequesterRsrc --keepParent "$ZIP_PATH/DreamVault.app" "$ZIP_PATH/DreamVault.zip"
echo "    zip: $ZIP_PATH/DreamVault.zip"

# —— 6. notarytool submit + wait + staple ——
echo "==> [6/7] notarytool submit (this may take 1-5 min)..."
xcrun notarytool submit "$ZIP_PATH/DreamVault.zip" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait 2>&1
xcrun notarytool staple "$APP_DIR" 2>&1
echo "    staple OK"

# —— 7. 验 + 打 DMG ——
echo "==> [7/7] Final verify + DMG..."
spctl --assess --type execute -vv "$APP_DIR" 2>&1
stapler validate "$APP_DIR" 2>&1 || xcrun stapler validate "$APP_DIR" 2>&1
# 打 DMG
DMG_PATH="$HOME/Desktop/DreamVault-${BUNDLE_VERSION}.dmg"
DMG_STAGING="$(mktemp -d -t dv-dmg)"
cp -R "$APP_DIR" "$DMG_STAGING/DreamVault.app"
ln -s /Applications "$DMG_STAGING/Applications"
SIZE_KB=$(du -sk "$DMG_STAGING" | awk '{print int($1 * 1.2)}')
hdiutil create \
    -volname "DreamVault ${BUNDLE_VERSION}" \
    -srcfolder "$DMG_STAGING" \
    -ov \
    -format UDZO \
    -fs HFS+ \
    -size "${SIZE_KB}k" \
    "$DMG_PATH" 2>&1 | tail -2
/Users/biomatrix/.mavis/bin/mavis-trash "$DMG_STAGING" 2>&1 || /bin/rm -rf "$DMG_STAGING"
/Users/biomatrix/.mavis/bin/mavis-trash "$ZIP_PATH" 2>&1 || /bin/rm -rf "$ZIP_PATH"

echo
echo "==> Done!"
echo "    App:  $APP_DIR"
echo "    DMG:  $DMG_PATH"
echo
echo "spctl 期望：accepted（不再是 override=security disabled）"
echo "staple 期望：stapled ticket present"
ls -la "$DMG_PATH"
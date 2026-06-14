#!/usr/bin/env bash
# Build the SwiftPM GUI product into a macOS .app bundle.
#
# Default output:
#   ~/Applications/DreamVault.app
#
# Useful overrides:
#   DREAMVAULT_APP_DIR=/path/DreamVault.app bash scripts/build-app.sh
#   DREAMVAULT_VERSION=0.3.0 bash scripts/build-app.sh
#   DREAMVAULT_SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" bash scripts/build-app.sh
#   DREAMVAULT_DISTRIBUTION=1 DREAMVAULT_SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" bash scripts/build-app.sh
#
# Signing policy:
#   - distribution build requires a Developer ID Application identity
#   - local build uses the requested identity, an auto-detected identity, or ad-hoc signing
#   - DREAMVAULT_SKIP_SIGN=1 leaves the app unsigned and is only for low-level diagnosis

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="${DREAMVAULT_APP_DIR:-$HOME/Applications/DreamVault.app}"
CONTENTS="$APP_DIR/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
SOURCE_BIN="$REPO/.build/release/dream"
DEFAULT_VERSION="$(git -C "$REPO" describe --tags --match 'v[0-9]*' --abbrev=0 2>/dev/null | sed 's/^v//' || true)"
BUNDLE_VERSION="${DREAMVAULT_VERSION:-${DEFAULT_VERSION:-0.3.0}}"
BUNDLE_ID="${DREAMVAULT_BUNDLE_ID:-com.OmixNet.dreamvault.gui}"
DISTRIBUTION="${DREAMVAULT_DISTRIBUTION:-0}"
SIGN_IDENTITY="${DREAMVAULT_SIGN_IDENTITY:-}"

safe_remove_app() {
    case "$1" in
        ""|"/"|"$HOME"|"/Applications"|"$HOME/Applications")
            echo "ERROR: refusing to remove unsafe app path: $1" >&2
            exit 1
            ;;
        *.app) /bin/rm -rf "$1" ;;
        *)
            echo "ERROR: DREAMVAULT_APP_DIR must end with .app: $1" >&2
            exit 1
            ;;
    esac
}

write_info_plist() {
    cat > "$CONTENTS/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>DreamVault</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
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
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIconName</key>
    <string>AppIcon</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>LSUIElement</key>
    <false/>
    <key>NSSupportsAutomaticTermination</key>
    <false/>
    <key>NSQuitAlwaysKeepsWindows</key>
    <false/>
    <key>NSHumanReadableCopyright</key>
    <string>DreamVault GUI - local-first knowledge base and nightly dream.</string>
</dict>
</plist>
EOF
}

echo "==> [1/5] swift build -c release..."
XCTOOL=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin
export PATH="$XCTOOL:$PATH"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$REPO/.build/clang-module-cache}"
mkdir -p "$CLANG_MODULE_CACHE_PATH" "$REPO/.build/swift-module-cache"
(cd "$REPO" && /usr/bin/swift build \
    --package-path "$REPO" \
    --disable-sandbox \
    -c release \
    -Xswiftc -module-cache-path \
    -Xswiftc "$REPO/.build/swift-module-cache")
if [ ! -x "$SOURCE_BIN" ]; then
    echo "ERROR: $SOURCE_BIN was not produced" >&2
    exit 1
fi
echo "    binary: $SOURCE_BIN"

echo "==> [2/5] Creating .app bundle at $APP_DIR..."
mkdir -p "$(dirname "$APP_DIR")"
safe_remove_app "$APP_DIR"
mkdir -p "$MACOS" "$RESOURCES"
cp "$SOURCE_BIN" "$MACOS/DreamVault"
chmod +x "$MACOS/DreamVault"

if [ -f "$REPO/Resources/AppIcon.icns" ]; then
    cp "$REPO/Resources/AppIcon.icns" "$RESOURCES/AppIcon.icns"
    echo "    AppIcon: $(wc -c < "$RESOURCES/AppIcon.icns" | tr -d ' ') bytes"
fi

echo "==> [3/5] Writing Info.plist..."
write_info_plist
plutil -lint "$CONTENTS/Info.plist" >/dev/null
plutil -extract CFBundleIdentifier raw "$CONTENTS/Info.plist" >/dev/null
echo "    bundle id: $BUNDLE_ID"
echo "    version:   $BUNDLE_VERSION"

echo "==> [4/5] Code signing..."
if [ -n "${DREAMVAULT_SKIP_SIGN:-}" ]; then
    echo "    SKIPPED (DREAMVAULT_SKIP_SIGN=1)"
else
    if [ "$DISTRIBUTION" = "1" ]; then
        if [ -z "$SIGN_IDENTITY" ]; then
            echo "ERROR: DREAMVAULT_DISTRIBUTION=1 requires DREAMVAULT_SIGN_IDENTITY" >&2
            exit 1
        fi
        if ! security find-identity -p codesigning -v 2>/dev/null | grep -F "$SIGN_IDENTITY" >/dev/null; then
            echo "ERROR: signing identity not found: $SIGN_IDENTITY" >&2
            exit 1
        fi
        if [[ "$SIGN_IDENTITY" != Developer\ ID\ Application:* ]]; then
            echo "ERROR: distribution signing requires a Developer ID Application identity" >&2
            exit 1
        fi
        echo "    Developer ID: $SIGN_IDENTITY"
        codesign --force --deep --options=runtime --timestamp --sign "$SIGN_IDENTITY" "$APP_DIR"
    else
        if [ -z "$SIGN_IDENTITY" ]; then
            SIGN_IDENTITY="$(security find-identity -p codesigning -v 2>/dev/null | awk -F'"' '/"/ {print $2; exit}' || true)"
        fi
        if [ -n "$SIGN_IDENTITY" ]; then
            echo "    identity: $SIGN_IDENTITY"
            codesign --force --deep --options=runtime --sign "$SIGN_IDENTITY" "$APP_DIR"
        else
            echo "    identity: ad-hoc (-)"
            codesign --force --deep --options=runtime --sign - "$APP_DIR"
        fi
    fi
fi

echo "==> [5/5] Validating .app..."
plutil -p "$CONTENTS/Info.plist" | head -3
if [ -z "${DREAMVAULT_SKIP_SIGN:-}" ]; then
    codesign --verify --deep --strict --verbose=2 "$APP_DIR"
    codesign -dv "$APP_DIR" 2>&1 | sed -n '1,8p' | sed 's/^/    /'
    spctl --assess --type execute -vv "$APP_DIR" 2>&1 | sed -n '1,4p' | sed 's/^/    /' || true
else
    echo "    unsigned app; release-check will fail distribution mode"
fi

echo
echo "==> Done"
echo "    App: $APP_DIR"
echo
echo "Launch:"
echo "  open -n \"$APP_DIR\""
echo
echo "Build DMG:"
echo "  DREAMVAULT_APP_DIR=\"$APP_DIR\" bash scripts/build-dmg.sh"

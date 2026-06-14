#!/usr/bin/env bash
# Build a drag-to-Applications DMG from a prepared DreamVault.app.
#
# Defaults:
#   app: ~/Applications/DreamVault.app
#   dmg: ~/Desktop/DreamVault-<CFBundleShortVersionString>.dmg
#
# Useful overrides:
#   DREAMVAULT_APP_DIR=/path/DreamVault.app DREAMVAULT_DMG_PATH=/path/DreamVault.dmg bash scripts/build-dmg.sh

set -euo pipefail

APP_DIR="${DREAMVAULT_APP_DIR:-$HOME/Applications/DreamVault.app}"
if [ ! -d "$APP_DIR" ]; then
    echo "ERROR: $APP_DIR does not exist. Run scripts/build-app.sh first." >&2
    exit 1
fi

VERSION="${DREAMVAULT_VERSION:-$(plutil -extract CFBundleShortVersionString raw "$APP_DIR/Contents/Info.plist" 2>/dev/null || echo "0.3.0")}"
DMG_NAME="DreamVault-${VERSION}"
DMG_PATH="${DREAMVAULT_DMG_PATH:-$HOME/Desktop/${DMG_NAME}.dmg}"
STAGING="$(mktemp -d -t dv-dmg-staging)"
trap '/bin/rm -rf "$STAGING"' EXIT

echo "==> [1/5] Validating source app..."
plutil -lint "$APP_DIR/Contents/Info.plist" >/dev/null
if codesign --verify --deep --strict --verbose=2 "$APP_DIR" >/dev/null 2>&1; then
    echo "    codesign: valid"
else
    echo "    WARNING: app signature is missing or invalid; DMG will not be distribution-ready"
fi
codesign -dv "$APP_DIR" 2>&1 | sed -n '1,8p' | sed 's/^/    /' || true

echo "==> [2/5] Preparing staging directory..."
cp -R "$APP_DIR" "$STAGING/DreamVault.app"
ln -s /Applications "$STAGING/Applications"
ls -la "$STAGING"

echo "==> [3/5] Creating compressed DMG..."
mkdir -p "$(dirname "$DMG_PATH")"
if [ -e "$DMG_PATH" ]; then
    /bin/rm -f "$DMG_PATH"
fi
SIZE_KB="$(du -sk "$STAGING" | awk '{print int($1 * 1.2) + 1024}')"
hdiutil create \
    -volname "$DMG_NAME" \
    -srcfolder "$STAGING" \
    -ov \
    -format UDZO \
    -fs HFS+ \
    -size "${SIZE_KB}k" \
    "$DMG_PATH" 2>&1 | tail -3

echo "==> [4/5] Verifying DMG image..."
hdiutil verify "$DMG_PATH" >/dev/null

echo "==> [5/5] Mount smoke check..."
MOUNT_OUT="$(hdiutil attach -nobrowse -readonly "$DMG_PATH" 2>&1)"
MOUNT_POINT="$(echo "$MOUNT_OUT" | awk '/\/Volumes\// {print $NF; exit}')"
if [ -z "$MOUNT_POINT" ] || [ ! -d "$MOUNT_POINT" ]; then
    echo "ERROR: failed to mount DMG" >&2
    echo "$MOUNT_OUT" >&2
    exit 1
fi
echo "    mounted: $MOUNT_POINT"
test -d "$MOUNT_POINT/DreamVault.app"
test -L "$MOUNT_POINT/Applications"
hdiutil detach "$MOUNT_POINT" >/dev/null

echo
echo "==> Done"
echo "    DMG: $DMG_PATH"
ls -la "$DMG_PATH"

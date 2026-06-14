#!/usr/bin/env bash
# Validate a built DreamVault.app and, optionally, a DMG for local/friend use.
#
# Local check:
#   bash scripts/release-check.sh
#
# Formal distribution gate, only if needed:
#   DREAMVAULT_REQUIRE_DISTRIBUTION=1 bash scripts/release-check.sh
#
# Custom artifacts:
#   DREAMVAULT_APP_DIR=/path/DreamVault.app DREAMVAULT_DMG_PATH=/path/DreamVault.dmg bash scripts/release-check.sh

set -euo pipefail

APP_DIR="${DREAMVAULT_APP_DIR:-$HOME/Applications/DreamVault.app}"
DMG_PATH="${DREAMVAULT_DMG_PATH:-}"
REQUIRE_DISTRIBUTION="${DREAMVAULT_REQUIRE_DISTRIBUTION:-0}"
FAIL=0

check() {
    local label="$1"
    shift
    if "$@" >/tmp/dv-release-check.out 2>&1; then
        echo "    ✓ $label"
    else
        echo "    ✗ $label"
        sed 's/^/      /' /tmp/dv-release-check.out
        FAIL=1
    fi
}

warn_check() {
    local label="$1"
    shift
    if "$@" >/tmp/dv-release-check.out 2>&1; then
        echo "    ✓ $label"
    else
        echo "    ⚠ $label"
        sed 's/^/      /' /tmp/dv-release-check.out
        if [ "$REQUIRE_DISTRIBUTION" = "1" ]; then
            FAIL=1
        fi
    fi
}

if [ ! -d "$APP_DIR" ]; then
    echo "ERROR: app not found: $APP_DIR" >&2
    exit 1
fi

echo "==> App bundle"
check "Info.plist lint" plutil -lint "$APP_DIR/Contents/Info.plist"
check "main executable exists" test -x "$APP_DIR/Contents/MacOS/DreamVault"
check "bundle package type is APPL" bash -c "[ \"$(plutil -extract CFBundlePackageType raw "$APP_DIR/Contents/Info.plist")\" = APPL ]"
check "bundle executable is DreamVault" bash -c "[ \"$(plutil -extract CFBundleExecutable raw "$APP_DIR/Contents/Info.plist")\" = DreamVault ]"

echo "==> Code signing"
warn_check "codesign verify deep strict" codesign --verify --deep --strict --verbose=2 "$APP_DIR"
SIGN_INFO="$(codesign -dv "$APP_DIR" 2>&1 || true)"
echo "$SIGN_INFO" | sed -n '1,10p' | sed 's/^/    /'
if echo "$SIGN_INFO" | grep -q "Signature=adhoc"; then
    if [ "$REQUIRE_DISTRIBUTION" = "1" ]; then
        echo "    ⚠ signature class: ad-hoc development signing"
        FAIL=1
    else
        echo "    ℹ signature class: ad-hoc local signing"
    fi
elif echo "$SIGN_INFO" | grep -q "Authority=Developer ID Application"; then
    echo "    ✓ signature class: Developer ID Application"
else
    echo "    ⚠ signature class: not Developer ID Application"
    if [ "$REQUIRE_DISTRIBUTION" = "1" ]; then FAIL=1; fi
fi
warn_check "Gatekeeper assessment" spctl --assess --type execute -vv "$APP_DIR"

echo "==> Notarization"
if xcrun stapler validate "$APP_DIR" >/tmp/dv-release-check.out 2>&1; then
    echo "    ✓ stapled notarization ticket"
else
    if [ "$REQUIRE_DISTRIBUTION" = "1" ]; then
        echo "    ⚠ no stapled app ticket"
    else
        echo "    ℹ no stapled app ticket (fine for self/friend use)"
    fi
    sed 's/^/      /' /tmp/dv-release-check.out
    if [ "$REQUIRE_DISTRIBUTION" = "1" ]; then FAIL=1; fi
fi

if [ -n "$DMG_PATH" ]; then
    echo "==> DMG"
    check "DMG exists" test -f "$DMG_PATH"
    check "hdiutil verify" hdiutil verify "$DMG_PATH"
    MOUNT_OUT="$(hdiutil attach -nobrowse -readonly "$DMG_PATH" 2>&1)"
    MOUNT_POINT="$(echo "$MOUNT_OUT" | awk '/\/Volumes\// {print $NF; exit}')"
    if [ -n "$MOUNT_POINT" ] && [ -d "$MOUNT_POINT" ]; then
        echo "    ✓ DMG mount"
        test -d "$MOUNT_POINT/DreamVault.app" || { echo "    ✗ DreamVault.app missing in DMG"; FAIL=1; }
        test -L "$MOUNT_POINT/Applications" || { echo "    ✗ Applications link missing in DMG"; FAIL=1; }
        hdiutil detach "$MOUNT_POINT" >/dev/null
    else
        echo "    ✗ DMG mount"
        echo "$MOUNT_OUT" | sed 's/^/      /'
        FAIL=1
    fi
fi

if [ "$FAIL" = "1" ]; then
    echo "PACKAGE CHECK failed" >&2
    exit 1
fi

echo "PACKAGE CHECK passed"

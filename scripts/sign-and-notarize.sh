#!/usr/bin/env bash
# Build, Developer-ID sign, notarize, staple, and package DreamVault.
#
# Prerequisites:
#   1. Apple Developer Program membership.
#   2. Developer ID Application certificate imported into the login keychain.
#   3. A notarytool keychain profile:
#      xcrun notarytool store-credentials "DreamVaultNotary" \
#        --apple-id "you@example.com" --team-id "ABCDE12345" \
#        --password "app-specific-password"
#
# Usage:
#   DREAMVAULT_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
#   DREAMVAULT_NOTARY_PROFILE="DreamVaultNotary" \
#   DREAMVAULT_VERSION="0.3.0" \
#   bash scripts/sign-and-notarize.sh

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="${DREAMVAULT_APP_DIR:-$HOME/Applications/DreamVault.app}"
BUNDLE_VERSION="${DREAMVAULT_VERSION:-0.3.0}"
DMG_PATH="${DREAMVAULT_DMG_PATH:-$HOME/Desktop/DreamVault-${BUNDLE_VERSION}.dmg}"
NOTARY_PROFILE="${DREAMVAULT_NOTARY_PROFILE:-}"
SIGN_IDENTITY="${DREAMVAULT_SIGN_IDENTITY:-}"
ZIP_DIR="$(mktemp -d -t dv-notary)"
trap '/bin/rm -rf "$ZIP_DIR"' EXIT

if [ -z "$SIGN_IDENTITY" ]; then
    echo "ERROR: DREAMVAULT_SIGN_IDENTITY is required" >&2
    exit 1
fi
if [ -z "$NOTARY_PROFILE" ]; then
    echo "ERROR: DREAMVAULT_NOTARY_PROFILE is required" >&2
    exit 1
fi
if [[ "$SIGN_IDENTITY" != Developer\ ID\ Application:* ]]; then
    echo "ERROR: signing identity must be a Developer ID Application certificate" >&2
    exit 1
fi

echo "==> [1/6] Build and Developer-ID sign .app..."
DREAMVAULT_APP_DIR="$APP_DIR" \
DREAMVAULT_VERSION="$BUNDLE_VERSION" \
DREAMVAULT_DISTRIBUTION=1 \
DREAMVAULT_SIGN_IDENTITY="$SIGN_IDENTITY" \
bash "$REPO/scripts/build-app.sh"

echo "==> [2/6] Pack .app for notarytool..."
ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$ZIP_DIR/DreamVault.zip"
ls -la "$ZIP_DIR/DreamVault.zip"

echo "==> [3/6] Submit .app zip for notarization..."
xcrun notarytool submit "$ZIP_DIR/DreamVault.zip" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait

echo "==> [4/6] Staple and validate .app..."
xcrun stapler staple "$APP_DIR"
xcrun stapler validate "$APP_DIR"
spctl --assess --type execute -vv "$APP_DIR"

echo "==> [5/6] Build DMG..."
DREAMVAULT_APP_DIR="$APP_DIR" \
DREAMVAULT_DMG_PATH="$DMG_PATH" \
DREAMVAULT_VERSION="$BUNDLE_VERSION" \
bash "$REPO/scripts/build-dmg.sh"

echo "==> [6/6] Release readiness check..."
DREAMVAULT_APP_DIR="$APP_DIR" \
DREAMVAULT_DMG_PATH="$DMG_PATH" \
DREAMVAULT_REQUIRE_DISTRIBUTION=1 \
bash "$REPO/scripts/release-check.sh"

echo
echo "==> Done"
echo "    App: $APP_DIR"
echo "    DMG: $DMG_PATH"

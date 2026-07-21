#!/usr/bin/env bash
# build-dmg.sh — package CallBridge.app into a drag-to-Applications .dmg.
#
# Produces a compressed, read-only disk image whose window shows CallBridge.app
# next to a shortcut to /Applications, so a non-technical user installs by
# dragging the icon across — no terminal required.
#
# Usage: ./build-dmg.sh <version> [path/to/CallBridge.app] [output.dmg]
#   defaults: app = CallBridge/CallBridge.app,  output = CallBridge-<version>.dmg
#
# If DEVELOPER_ID_APP is set, the finished .dmg is code-signed with it (the app
# inside should already be signed + notarized before calling this).
set -euo pipefail

VERSION="${1:?Usage: build-dmg.sh <version> [app] [output.dmg]}"
APP_PATH="${2:-CallBridge/CallBridge.app}"
DMG_OUT="${3:-CallBridge-${VERSION}.dmg}"
VOL_NAME="CallBridge ${VERSION}"

if [ ! -d "$APP_PATH" ]; then
    echo "build-dmg: app not found: $APP_PATH" >&2
    exit 1
fi

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

echo "build-dmg: staging bundle..."
cp -R "$APP_PATH" "$STAGE/CallBridge.app"
# Shortcut so the user can drag the app onto /Applications inside the DMG.
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG_OUT"

echo "build-dmg: creating compressed image $DMG_OUT ..."
# UDZO = zlib-compressed read-only; the standard format for app distribution.
hdiutil create \
    -volname "$VOL_NAME" \
    -srcfolder "$STAGE" \
    -ov \
    -format UDZO \
    -fs HFS+ \
    "$DMG_OUT"

# Sign the disk image itself so its download carries a Developer ID signature
# (Gatekeeper checks the image as well as the stapled app inside it).
if [ -n "${DEVELOPER_ID_APP:-}" ]; then
    echo "build-dmg: signing DMG with $DEVELOPER_ID_APP ..."
    codesign --force --sign "$DEVELOPER_ID_APP" --timestamp "$DMG_OUT"
    codesign --verify --verbose=2 "$DMG_OUT"
else
    echo "build-dmg: DEVELOPER_ID_APP not set — DMG left unsigned."
fi

echo "build-dmg: done -> $DMG_OUT"

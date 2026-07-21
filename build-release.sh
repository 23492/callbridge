#!/bin/bash
set -e

VERSION=$1
if [ -z "$VERSION" ]; then
    echo "Usage: ./build-release.sh <version>"
    echo "Example: ./build-release.sh 1.2.0"
    exit 1
fi

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Error: VERSION must be in semver format (e.g. 1.2.0)"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# ----- Notarization helpers -----
# Credentials come from the environment (never committed). Two supported modes:
#   API key (preferred):  AC_API_KEY_ID, AC_API_ISSUER_ID, AC_API_KEY_PATH (.p8)
#   Apple ID:             AC_APPLE_ID, AC_TEAM_ID, AC_PASSWORD (app-specific pw)
have_notary_creds() {
    { [ -n "${AC_API_KEY_ID:-}" ] && [ -n "${AC_API_ISSUER_ID:-}" ] && [ -n "${AC_API_KEY_PATH:-}" ]; } || \
    { [ -n "${AC_APPLE_ID:-}" ] && [ -n "${AC_TEAM_ID:-}" ] && [ -n "${AC_PASSWORD:-}" ]; }
}

# notarize <path-to-zip-or-dmg> — submits and blocks until Apple returns a verdict.
notarize() {
    local artifact="$1"
    if [ -n "${AC_API_KEY_ID:-}" ]; then
        xcrun notarytool submit "$artifact" \
            --key "$AC_API_KEY_PATH" \
            --key-id "$AC_API_KEY_ID" \
            --issuer "$AC_API_ISSUER_ID" \
            --wait
    else
        xcrun notarytool submit "$artifact" \
            --apple-id "$AC_APPLE_ID" \
            --team-id "$AC_TEAM_ID" \
            --password "$AC_PASSWORD" \
            --wait
    fi
}

echo "=== Building CallBridge v${VERSION} ==="

# 1. Update version in main.swift
sed -i '' "s/^let appVersion = \".*\"/let appVersion = \"${VERSION}\"/" CallBridge/CallBridge/main.swift
echo "Updated appVersion in main.swift"

# 2. Update Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${VERSION}" CallBridge/CallBridge/Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" CallBridge/CallBridge/Info.plist
echo "Updated Info.plist"

# 3. Build
echo "Compiling..."
cd CallBridge
mkdir -p CallBridge.app/Contents/MacOS
swift build -c release
cp .build/release/CallBridge CallBridge.app/Contents/MacOS/CallBridge
cd ..
echo "Build succeeded"

# 3b. Build Python backend with PyInstaller (BACK-02, D-06, D-09)
echo "Building Python backend..."
VENV_DIR="$(mktemp -d)"
python3 -m venv "$VENV_DIR"
"$VENV_DIR/bin/pip" install --quiet -r requirements.txt pyinstaller
"$VENV_DIR/bin/pyinstaller" callbridge-server.spec --noconfirm --distpath CallBridge/CallBridge.app/Contents/Resources
rm -rf "$VENV_DIR"
echo "Python backend built"

# 4. Copy Info.plist into app bundle
cp CallBridge/CallBridge/Info.plist CallBridge/CallBridge.app/Contents/Info.plist

APP="CallBridge/CallBridge.app"

# 4b. Code-sign the bundle.
#   * DEVELOPER_ID_APP set  -> Developer ID + hardened runtime + entitlements
#                              (notarizable). Set it to your identity, e.g.
#                              "Developer ID Application: Welisa B.V. (TEAMID)".
#   * DEVELOPER_ID_APP unset -> ad-hoc signing, exactly as before, so macOS will
#                              still exec the embedded backend on the dev Mac.
echo "Code signing..."
scripts/codesign-app.sh "$APP"

# 4c. Notarize the app (only if notary credentials are present). notarytool
#     accepts a .zip; after approval we staple the ticket onto the .app so it
#     launches without a network round-trip. See notarize() in this script.
if have_notary_creds; then
    echo "Notarizing app..."
    NOTARIZE_ZIP="$(mktemp -d)/CallBridge-notarize.zip"
    ditto -c -k --keepParent "$APP" "$NOTARIZE_ZIP"
    notarize "$NOTARIZE_ZIP"
    echo "Stapling ticket onto app..."
    xcrun stapler staple "$APP"
    rm -f "$NOTARIZE_ZIP"
else
    echo "Skipping notarization (no notary credentials set — see docs/SIGNING-AND-DISTRIBUTION.md)."
fi

# 5. Create the auto-update zip from the (possibly stapled) app.
#    ditto preserves macOS metadata; the auto-updater downloads this exact file.
ZIP_NAME="CallBridge.app.zip"
rm -f "$ZIP_NAME"
cd CallBridge
ditto -c -k --keepParent CallBridge.app "../${ZIP_NAME}"
cd ..
echo "Created ${ZIP_NAME}"

# 5b. Build the drag-to-Applications .dmg (fresh-install distribution path) and
#     notarize + staple it too, so a clean Mac opens it without Gatekeeper
#     friction and installs with no terminal.
DMG_NAME="CallBridge-${VERSION}.dmg"
echo "Building DMG..."
./build-dmg.sh "$VERSION" "$APP" "$DMG_NAME"
if have_notary_creds; then
    echo "Notarizing DMG..."
    notarize "$DMG_NAME"
    echo "Stapling ticket onto DMG..."
    xcrun stapler staple "$DMG_NAME"
fi

# 6. EdDSA-sign the zip for the auto-updater manifest.
echo "Signing update..."
SIGNATURE=$(swift sign-update.swift "$ZIP_NAME")
echo "Signature: ${SIGNATURE}"

# 7. Update manifest
cat > callbridge-update.json <<MANIFEST
{
  "version": "${VERSION}",
  "url": "https://github.com/23492/callbridge/releases/download/v${VERSION}/CallBridge.app.zip",
  "signature": "${SIGNATURE}",
  "notes": ""
}
MANIFEST
echo "Updated callbridge-update.json"

echo ""
echo "=== Release v${VERSION} ready ==="
if have_notary_creds; then
    echo "  Signed with Developer ID + notarized + stapled (app zip and DMG)."
else
    echo "  NOTE: ad-hoc signed, NOT notarized (no Developer ID / notary creds set)."
    echo "        See docs/SIGNING-AND-DISTRIBUTION.md to produce a distributable build."
fi
echo ""
echo "Artifacts:"
echo "  ${ZIP_NAME}   (auto-update payload; referenced by callbridge-update.json)"
echo "  ${DMG_NAME}   (drag-to-Applications installer for fresh Macs)"
echo ""
echo "Next steps:"
echo "  1. Edit callbridge-update.json to add release notes"
echo "  2. git add -A && git commit -m 'Release v${VERSION}' && git push"
echo "  3. gh release create v${VERSION} ${ZIP_NAME} ${DMG_NAME} --title 'v${VERSION}' --notes '...'"
echo ""
echo "To deploy locally now:"
echo "  pkill -f CallBridge.app; sleep 1; rm -rf /Applications/CallBridge.app && cp -R CallBridge/CallBridge.app /Applications/CallBridge.app && open /Applications/CallBridge.app"
echo ""
echo "For LaunchAgent installation and migration instructions, see: launchagents/README.md"

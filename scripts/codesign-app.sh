#!/usr/bin/env bash
# codesign-app.sh — sign CallBridge.app for distribution.
#
# Deep-signs every nested Mach-O binary (the embedded PyInstaller Python
# backend and all its .dylib / .so extension modules) and then the app bundle
# itself, so the result passes notarization and runs under the hardened runtime.
#
# Signing identity is chosen from the environment:
#   * DEVELOPER_ID_APP set  -> real Developer ID Application signing with the
#                              hardened runtime, a secure timestamp, and the
#                              app's entitlements. Produces a notarizable app.
#   * DEVELOPER_ID_APP empty -> ad-hoc signing ("-"), no hardened runtime.
#                              Keeps local/dev builds working exactly as before;
#                              such a build cannot be notarized.
#
# Usage: scripts/codesign-app.sh /path/to/CallBridge.app
#
# Env:
#   DEVELOPER_ID_APP   e.g. "Developer ID Application: Welisa B.V. (TEAMID1234)"
#   ENTITLEMENTS       path to entitlements.plist
#                      (default: <repo>/CallBridge/entitlements.plist)
set -euo pipefail

APP_PATH="${1:?Usage: codesign-app.sh /path/to/CallBridge.app}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENTITLEMENTS="${ENTITLEMENTS:-$REPO_ROOT/CallBridge/entitlements.plist}"

if [ ! -d "$APP_PATH" ]; then
    echo "codesign-app: app not found: $APP_PATH" >&2
    exit 1
fi

# ----- Pick the signing identity -----
if [ -n "${DEVELOPER_ID_APP:-}" ]; then
    IDENTITY="$DEVELOPER_ID_APP"
    HARDENED=(--options runtime --timestamp)
    echo "codesign-app: Developer ID signing as: $IDENTITY"
    if [ ! -f "$ENTITLEMENTS" ]; then
        echo "codesign-app: entitlements not found: $ENTITLEMENTS" >&2
        exit 1
    fi
    ENT_ARGS=(--entitlements "$ENTITLEMENTS")
else
    IDENTITY="-"
    HARDENED=()
    ENT_ARGS=()
    echo "codesign-app: DEVELOPER_ID_APP not set — ad-hoc signing (not notarizable)."
fi

sign_one() {
    # $1 = path to a Mach-O file or bundle
    codesign --force --sign "$IDENTITY" "${HARDENED[@]}" "${ENT_ARGS[@]}" "$1"
}

# ----- 1. Sign nested Mach-O files first (deepest-first), then the app -----
# The embedded backend lives at Contents/Resources/callbridge-server/. Sign
# every Mach-O binary inside the bundle (dylibs, .so, and the backend exe)
# before sealing the outer app. We identify Mach-O files by `file` output so we
# don't waste time signing plain data files.
echo "codesign-app: signing nested binaries..."
NESTED_COUNT=0
while IFS= read -r -d '' f; do
    if file -b "$f" | grep -q 'Mach-O'; then
        sign_one "$f"
        NESTED_COUNT=$((NESTED_COUNT + 1))
    fi
done < <(find "$APP_PATH/Contents/Resources" "$APP_PATH/Contents/Frameworks" \
             -type f \( -perm -u+x -o -name '*.dylib' -o -name '*.so' \) -print0 2>/dev/null)
echo "codesign-app: signed $NESTED_COUNT nested Mach-O file(s)."

# ----- 2. Sign the main app executable, then the bundle -----
echo "codesign-app: signing app bundle..."
sign_one "$APP_PATH/Contents/MacOS/CallBridge"
sign_one "$APP_PATH"

# ----- 3. Verify -----
echo "codesign-app: verifying signature..."
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
if [ "$IDENTITY" != "-" ]; then
    # Gatekeeper assessment only meaningful for real (notarizable) signatures.
    spctl --assess --type execute --verbose "$APP_PATH" || \
        echo "codesign-app: spctl assessment not yet accepted (expected until notarization staples a ticket)."
fi
echo "codesign-app: done."

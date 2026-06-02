#!/bin/bash
set -e

VERSION=$1
if [ -z "$VERSION" ]; then
    echo "Usage: ./build-release.sh <version>"
    echo "Example: ./build-release.sh 1.2.0"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

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
swiftc -o CallBridge.app/Contents/MacOS/CallBridge CallBridge/main.swift -framework Cocoa -framework SwiftUI
cd ..
echo "Build succeeded"

# 4. Copy Info.plist into app bundle
cp CallBridge/CallBridge/Info.plist CallBridge/CallBridge.app/Contents/Info.plist

# 5. Create zip (ditto preserves macOS metadata)
ZIP_NAME="CallBridge.app.zip"
rm -f "$ZIP_NAME"
cd CallBridge
ditto -c -k --keepParent CallBridge.app "../${ZIP_NAME}"
cd ..
echo "Created ${ZIP_NAME}"

# 6. Sign the zip
echo "Signing..."
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
echo ""
echo "Next steps:"
echo "  1. Edit callbridge-update.json to add release notes"
echo "  2. git add -A && git commit -m 'Release v${VERSION}' && git push"
echo "  3. gh release create v${VERSION} ${ZIP_NAME} --title 'v${VERSION}' --notes '...'"
echo ""
echo "To deploy locally now:"
echo "  pkill -f CallBridge.app; sleep 1; rm -rf /Applications/CallBridge.app && cp -R CallBridge/CallBridge.app /Applications/CallBridge.app && open /Applications/CallBridge.app"

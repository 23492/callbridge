#!/bin/bash
# Compiles the pure update-channel section of main.swift together with
# tests/UpdateChannelTests.swift and runs it. No Cocoa needed (runs on macOS or Linux).
set -euo pipefail
cd "$(dirname "$0")/.."
SRC=CallBridge/CallBridge/main.swift
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

{
  echo "import Foundation"
  grep -E '^let (appVersion|appBuildChannel) = ' "$SRC"
  echo 'func debugLog(_ m: String) {}'
  awk '/^\/\/ MARK: - Update Channel/{on=1} /^\/\/ MARK: - Update Manifest/{on=0} on' "$SRC"
} > "$WORK/Channel.swift"
cp tests/UpdateChannelTests.swift "$WORK/main.swift"

"${SWIFTC:-swiftc}" -module-cache-path "$WORK/cache" "$WORK/Channel.swift" "$WORK/main.swift" -o "$WORK/test"
"$WORK/test"

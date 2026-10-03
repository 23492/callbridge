#!/bin/bash
# Runs tests/UpdateChannelTests.swift against CallBridge/CallBridge/Core/UpdateChannel.swift
# via scripts/test-core.sh (no section slicing of main.swift). No Cocoa needed (macOS or Linux).
# Kept as a wrapper so the existing CI step name and command keep working.
set -euo pipefail
cd "$(dirname "$0")/.."
exec ./scripts/test-core.sh tests/UpdateChannelTests.swift

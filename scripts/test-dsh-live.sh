#!/bin/bash
# Live contract test of the CallBridge DSH client against the cockpit test routes
# (D-26). Compiles CallBridge/CallBridge/Core/*.swift, Infra/Cloudflared.swift,
# Infra/DSHClient.swift and tests/live/DSHLive.swift into one binary and runs it.
# Mac only: needs cloudflared, a `cloudflared access login https://dsh2.knoppsmart.com/cockpit/api/callbridge/v1/health`
# and a paired client token in DSH_CLIENT_TOKEN. It only calls test/ routes, which never
# reach Salesforce, AssemblyAI or an agent. The token reaches the binary only through the
# inherited environment, never as an argument, and is never printed.
# Usage: scripts/test-dsh-live.sh [echo|scenarios|resend|all]   (default all)
# SWIFTC overrides the compiler.
set -euo pipefail
cd "$(dirname "$0")/.."

MODE="${1:-all}"

if [ -z "${DSH_CLIENT_TOKEN:-}" ]; then
  # Single quotes on purpose: the hint must never run `security` and print the token (D-06).
  printf '%s\n' 'DSH_CLIENT_TOKEN ontbreekt: export DSH_CLIENT_TOKEN="$(security find-generic-password -s com.welisa.CallBridge -a DSH_CLIENT_TOKEN -w)"' >&2
  exit 2
fi

case "$MODE" in
  echo|scenarios|resend|all) ;;
  *) echo "Onbekende modus: $MODE (echo, scenarios, resend of all)" >&2; exit 2 ;;
esac

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

{
  echo "import Foundation"
  grep -E '^let (appVersion|appBuildChannel) = ' CallBridge/CallBridge/main.swift
  echo 'func debugLog(_ m: String) {}'
} > "$WORK/Stubs.swift"

mkdir -p "$WORK/live"
cp tests/live/DSHLive.swift "$WORK/live/main.swift"

"${SWIFTC:-swiftc}" -module-cache-path "$WORK/cache" "$WORK/Stubs.swift" \
    CallBridge/CallBridge/Core/*.swift \
    CallBridge/CallBridge/Infra/Cloudflared.swift \
    CallBridge/CallBridge/Infra/DSHClient.swift \
    "$WORK/live/main.swift" -o "$WORK/live/live"

"$WORK/live/live" "$MODE"

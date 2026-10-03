#!/bin/bash
# Compiles CallBridge/CallBridge/Core/*.swift with each tests/<Name>Tests.swift (one binary
# per test file, since top-level code is only allowed in main.swift) and runs it.
# No Cocoa, no XCTest: runs on macOS or Linux. Arguments select test files; the default is
# tests/*Tests.swift (tests/fixtures/ is excluded on purpose). SWIFTC overrides the compiler.
# Exits non-zero if any test fails to compile or fails at runtime; all tests still run.
set -euo pipefail
cd "$(dirname "$0")/.."
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

{
  echo "import Foundation"
  grep -E '^let (appVersion|appBuildChannel) = ' CallBridge/CallBridge/main.swift
  echo 'func debugLog(_ m: String) {}'
} > "$WORK/Stubs.swift"

TESTS=("$@")
[ ${#TESTS[@]} -eq 0 ] && TESTS=(tests/*Tests.swift)

status=0
for t in "${TESTS[@]}"; do
  name="$(basename "$t" .swift)"
  echo "== $name"
  mkdir -p "$WORK/$name"
  if ! cp "$t" "$WORK/$name/main.swift"; then
    echo "FAIL $name: cannot read $t"
    status=1
    continue
  fi
  rc=0
  "${SWIFTC:-swiftc}" -module-cache-path "$WORK/cache" "$WORK/Stubs.swift" \
      CallBridge/CallBridge/Core/*.swift "$WORK/$name/main.swift" -o "$WORK/$name/test" || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "FAIL $name: compile error (exit $rc)"
    status=1
    continue
  fi
  rc=0
  "$WORK/$name/test" || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "FAIL $name: exit $rc"
    status=1
  fi
done
exit $status

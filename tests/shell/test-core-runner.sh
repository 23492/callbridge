#!/bin/bash
# Self-test of scripts/test-core.sh that needs no Swift toolchain: a fake SWIFTC checks the
# arguments the runner passes and emits a stand-in test binary that fails when the test
# source contains "check(false". Proves the pass, fail, partial-fail and compile-fail
# directions. The real swiftc run happens on macOS (CI and the end-of-phase checkpoint).
set -euo pipefail
cd "$(dirname "$0")/../.."

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FAILS=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILS=$((FAILS+1)); }

FAKE="$TMP/fake-swiftc"
cat > "$FAKE" <<'FAKE_EOF'
#!/bin/bash
# Fake swiftc: validates inputs, writes a bash stand-in for the test binary.
out=""; src=""; have_core=0; have_stubs=0
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2; continue ;;
    -module-cache-path) shift 2; continue ;;
    CallBridge/CallBridge/Core/UpdateChannel.swift) have_core=1 ;;
    */Stubs.swift)
      if grep -q 'let appVersion = ' "$1" && grep -q 'func debugLog' "$1"; then have_stubs=1; fi ;;
    */main.swift) src="$1" ;;
  esac
  shift
done
if [ "$have_core" -ne 1 ] || [ "$have_stubs" -ne 1 ] || [ -z "$out" ] || [ -z "$src" ]; then
  echo "fake-swiftc: missing Core/UpdateChannel.swift, Stubs.swift, -o or main.swift" >&2
  exit 2
fi
if grep -q 'check(false' "$src"; then
  printf '#!/bin/bash\necho "1 FAILED"\nexit 1\n' > "$out"
else
  printf '#!/bin/bash\necho "ALL PASSED"\nexit 0\n' > "$out"
fi
chmod +x "$out"
FAKE_EOF
chmod +x "$FAKE"

BROKEN="$TMP/broken-swiftc"
printf '#!/bin/bash\necho "broken-swiftc: error" >&2\nexit 3\n' > "$BROKEN"
chmod +x "$BROKEN"

# (1) A passing test file makes the runner exit 0.
if SWIFTC="$FAKE" ./scripts/test-core.sh tests/UpdateChannelTests.swift > "$TMP/out1" 2>&1; then
  pass "passing test exits 0"
else
  fail "passing test exited non-zero"; cat "$TMP/out1"
fi

# (2) The negative control makes the runner exit non-zero.
if SWIFTC="$FAKE" ./scripts/test-core.sh tests/fixtures/AlwaysFailsTests.swift > "$TMP/out2" 2>&1; then
  fail "negative control exited 0"; cat "$TMP/out2"
else
  pass "negative control exits non-zero"
fi

# (3) A failing test does not stop the remaining tests, and still fails the run.
rc=0
SWIFTC="$FAKE" ./scripts/test-core.sh tests/fixtures/AlwaysFailsTests.swift tests/UpdateChannelTests.swift \
  > "$TMP/out3" 2>&1 || rc=$?
if [ "$rc" -ne 0 ] && grep -q '^== UpdateChannelTests' "$TMP/out3"; then
  pass "partial failure exits non-zero and still runs the next test"
else
  fail "partial failure: exit $rc, output follows"; cat "$TMP/out3"
fi

# (4) A compile error fails the run.
if SWIFTC="$BROKEN" ./scripts/test-core.sh tests/UpdateChannelTests.swift > "$TMP/out4" 2>&1; then
  fail "compile error exited 0"; cat "$TMP/out4"
else
  pass "compile error exits non-zero"
fi

if [ "$FAILS" -eq 0 ]; then
  echo "ALL RUNNER CHECKS PASSED"
  exit 0
fi
echo "$FAILS RUNNER CHECKS FAILED"
exit 1

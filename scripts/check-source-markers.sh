#!/bin/bash
# Guards the text that build-release.sh, release.yml and the Core test runner parse:
# the two version lines in main.swift, the sed rewrite that bumps them, the entry point,
# the Update Channel move into Core/, and the rule that Core/*.swift imports only Foundation.
# Pure bash/grep/sed, so it runs on macOS, Linux and CI without a Swift toolchain.
set -euo pipefail
cd "$(dirname "$0")/.."

SRC=CallBridge/CallBridge/main.swift
CORE_DIR=CallBridge/CallBridge/Core
CHANNEL_FILE="$CORE_DIR/UpdateChannel.swift"
RELEASE_YML=.github/workflows/release.yml

PASS_COUNT=0
FAIL_COUNT=0

pass() { echo "PASS: $1"; PASS_COUNT=$((PASS_COUNT+1)); }
fail() { echo "FAIL: $1"; FAIL_COUNT=$((FAIL_COUNT+1)); }

# (a) Exactly one version line and one channel line, at column 0.
for var in appVersion appBuildChannel; do
    n=$(grep -cE "^let ${var} = \"" "$SRC" || true)
    if [ "$n" -eq 1 ]; then
        pass "exactly one '^let ${var} = \"' line in $SRC"
    else
        fail "expected 1 '^let ${var} = \"' line in $SRC, found $n"
    fi
done

# (b) Simulate build-release.sh L32-33 without -i (portable across GNU and BSD sed).
# Sentinel values can never be real, so every matched line must change.
changed=$(sed -e 's/^let appVersion = ".*"/let appVersion = "__probe__"/' \
              -e 's/^let appBuildChannel = ".*"/let appBuildChannel = "__probe__"/' "$SRC" \
          | diff "$SRC" - | grep -c '^>' || true)
if [ "$changed" -eq 2 ]; then
    pass "simulated build-release.sh sed changes exactly 2 lines"
else
    fail "simulated build-release.sh sed changes $changed lines (expected 2)"
fi

# (c) release.yml still commits main.swift after the version bump.
if grep -q 'CallBridge/CallBridge/main.swift' "$RELEASE_YML"; then
    pass "$RELEASE_YML references CallBridge/CallBridge/main.swift"
else
    fail "$RELEASE_YML no longer references CallBridge/CallBridge/main.swift"
fi

# (d) main.swift keeps the entry point.
if grep -q 'app.run()' "$SRC"; then
    pass "$SRC contains the entry point (app.run())"
else
    fail "$SRC lost the entry point (app.run())"
fi

# (e) Update Channel logic lives in Core/.
if [ -f "$CHANNEL_FILE" ] && grep -q 'func decideUpdate(' "$CHANNEL_FILE"; then
    pass "$CHANNEL_FILE exists and defines decideUpdate"
else
    fail "$CHANNEL_FILE missing or without 'func decideUpdate('"
fi

# (f) The section is gone from main.swift (no duplicate definitions).
if grep -qF '// MARK: - Update Channel' "$SRC"; then
    fail "$SRC still contains '// MARK: - Update Channel'"
else
    pass "$SRC no longer contains the Update Channel section"
fi

# (g) Core/*.swift imports only Foundation, so scripts/test-core.sh can compile it anywhere.
shopt -s nullglob
core_files=("$CORE_DIR"/*.swift)
shopt -u nullglob
if [ ${#core_files[@]} -eq 0 ]; then
    fail "no Swift files in $CORE_DIR"
fi
for f in "${core_files[@]}"; do
    bad=$(grep -E '^import ' "$f" | grep -vxE 'import Foundation' || true)
    if [ -z "$bad" ]; then
        pass "$f imports only Foundation"
    else
        fail "$f imports more than Foundation: $(echo "$bad" | tr '\n' ' ')"
    fi
done

echo ""
echo "  PASS: $PASS_COUNT"
echo "  FAIL: $FAIL_COUNT"
if [ "$FAIL_COUNT" -eq 0 ]; then
    echo "ALL CHECKS PASSED"
    exit 0
else
    echo "SOME CHECKS FAILED"
    exit 1
fi

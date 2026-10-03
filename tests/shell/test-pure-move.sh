#!/bin/bash
# Negative control for scripts/check-pure-move.sh. Builds a throwaway git repo, then checks:
#   case 1: a section moved into its own file (plus an import line) passes;
#   case 2: the same move with one edited statement fails;
#   case 3: an unrelated new file fails without --ignore and passes with --ignore.
# Pure bash/git, no Swift toolchain needed.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CHECK="$ROOT/scripts/check-pure-move.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FAILS=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILS=$((FAILS+1)); }

cd "$TMP"
git init -q .
git config user.email "test@example.invalid"
git config user.name "pure-move test"
mkdir -p CallBridge/CallBridge
cat > CallBridge/CallBridge/main.swift <<'EOF'
import Foundation

// MARK: - Alpha

func alpha() -> Int {
    return 1
}

// MARK: - Beta

func beta() -> Int {
    return 2
}
EOF
git add CallBridge/CallBridge/main.swift
git commit -q -m "base"
BASE=$(git rev-parse HEAD)

# Case 1: move "Beta" into Infra/X.swift with an added import.
mkdir -p CallBridge/CallBridge/Infra
cat > CallBridge/CallBridge/main.swift <<'EOF'
import Foundation

// MARK: - Alpha

func alpha() -> Int {
    return 1
}
EOF
cat > CallBridge/CallBridge/Infra/X.swift <<'EOF'
import Foundation

// MARK: - Beta

func beta() -> Int {
    return 2
}
EOF
if out=$("$CHECK" "$BASE" 2>&1) && echo "$out" | grep -q 'PURE MOVE OK'; then
    pass "case 1: pure move with added import is accepted"
else
    fail "case 1: pure move was rejected: $out"
fi

# Case 2: same move, one statement edited.
sed -i.bak 's/return 2/return 3/' CallBridge/CallBridge/Infra/X.swift && rm -f CallBridge/CallBridge/Infra/X.swift.bak
if "$CHECK" "$BASE" >/dev/null 2>&1; then
    fail "case 2: edited statement was not detected"
else
    pass "case 2: edited statement is rejected"
fi
sed -i.bak 's/return 3/return 2/' CallBridge/CallBridge/Infra/X.swift && rm -f CallBridge/CallBridge/Infra/X.swift.bak

# Case 3: an unrelated new file, without and with --ignore.
mkdir -p CallBridge/CallBridge/Core
printf 'import Foundation\n\nlet unrelated = 42\n' > CallBridge/CallBridge/Core/New.swift
if "$CHECK" "$BASE" >/dev/null 2>&1; then
    fail "case 3: new file without --ignore was not detected"
elif out=$("$CHECK" --ignore CallBridge/CallBridge/Core/New.swift --ignore CallBridge/CallBridge/Core/Missing.swift "$BASE" 2>&1) \
     && echo "$out" | grep -q 'PURE MOVE OK'; then
    pass "case 3: new file rejected without --ignore, accepted with --ignore"
else
    fail "case 3: --ignore did not exclude the new file: $out"
fi

if [ "$FAILS" -eq 0 ]; then
    echo "ALL PURE-MOVE TESTS PASSED"
    exit 0
else
    echo "$FAILS PURE-MOVE TEST(S) FAILED"
    exit 1
fi

#!/bin/bash
# Phase 3 verification in one command. Runs every automated check that needs macOS (swiftc,
# swift build, pip, cloudflared, the paired client token) plus the checks that also run on
# Linux, in the order of .github/workflows/build.yml. Each step reports PASS, FAIL or SKIP;
# the summary decides the exit code (SKIP never fails the run but is listed).
#
# Usage:
#   scripts/verify-phase3-mac.sh             all steps (Kiran's Mac)
#   scripts/verify-phase3-mac.sh --linux     marker guard, Core runner shell test, Python suite
#                                            with the system python3, syntax check of the live
#                                            test script and a self-test of the DSH gate
#   scripts/verify-phase3-mac.sh --dsh-gate  only the DSH gate (before the real call)
#
# Env:
#   DSH_CLIENT_TOKEN          paired client token; step 7 (live contract test) runs only when set
#   CALLBRIDGE_SESSIONS_DIR   overrides the sessions directory the gate reads
#
# Read-only towards remotes and Salesforce: no remote git operation, no release, never starts
# the app, never prints the client token.
set -uo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SELF="$PROJECT_ROOT/scripts/verify-phase3-mac.sh"
cd "$PROJECT_ROOT"

MODE=full
case "${1:-}" in
    "") ;;
    --linux) MODE=linux ;;
    --dsh-gate) MODE=gate ;;
    -h|--help)
        sed -n 2,20p "$0"
        exit 0
        ;;
    *)
        echo "usage: $0 [--linux | --dsh-gate]" >&2
        exit 2
        ;;
esac

# --- DSH gate ------------------------------------------------------------------------------
# Guards the switch from the test routes and dry-run to the one real call: the app is not
# running, the test-route flag is off, and no session record is non-terminal or failed (a
# relaunch would resend those). Only reads; never moves, deletes or writes anything.
dsh_gate() {
    local dir="${CALLBRIDGE_SESSIONS_DIR:-$HOME/Library/Application Support/com.welisa.CallBridge/sessions}"
    local ok=1
    echo "sessions dir: $dir"

    if command -v pgrep >/dev/null 2>&1; then
        if pgrep -f 'CallBridge.app/Contents/MacOS/CallBridge' >/dev/null 2>&1; then
            echo "FAIL: CallBridge draait nog, sluit de app eerst af"
            ok=0
        fi
    else
        echo "note: pgrep not installed, skipping the running-app check"
    fi

    if command -v defaults >/dev/null 2>&1; then
        local flag
        flag=$(defaults read com.welisa.callbridge dshUseTestRoutes 2>/dev/null || true)
        if [ "$flag" = "1" ]; then
            echo "FAIL: dshUseTestRoutes staat nog aan"
            ok=0
        else
            echo "dshUseTestRoutes: off"
        fi
    else
        echo "note: defaults not installed (not macOS), skipping the dshUseTestRoutes check"
    fi

    local out
    out=$(python3 - "$dir" <<'PY'
import json, os, sys
d = sys.argv[1]
terminal = {"done", "failed", "discarded"}
non_terminal, failed, lines = 0, 0, []
if os.path.isdir(d):
    for name in sorted(os.listdir(d)):
        if not name.endswith(".json"):
            continue
        path = os.path.join(d, name)
        try:
            with open(path, encoding="utf-8") as fh:
                stage = json.load(fh).get("stage")
        except Exception:
            non_terminal += 1
            lines.append(f"{name} unreadable")
            continue
        if stage == "failed":
            failed += 1
            lines.append(f"{name} failed")
        elif stage not in terminal:
            non_terminal += 1
            lines.append(f"{name} {stage}")
print(f"non-terminal sessions: {non_terminal}")
print(f"failed sessions: {failed}")
for line in lines:
    print(line)
print("COUNTS", non_terminal, failed)
PY
)
    local rc=$?
    echo "$out" | grep -v '^COUNTS '
    if [ "$rc" -ne 0 ]; then
        ok=0
    else
        local counts n m
        counts=$(echo "$out" | grep '^COUNTS ')
        n=$(echo "$counts" | awk '{print $2}')
        m=$(echo "$counts" | awk '{print $3}')
        if [ "$n" != "0" ] || [ "$m" != "0" ]; then
            ok=0
        fi
    fi

    if [ "$ok" -eq 1 ]; then
        echo "DSH GATE OK"
        return 0
    fi
    echo "FAIL: DSH gate"
    return 1
}

if [ "$MODE" = gate ]; then
    dsh_gate
    exit $?
fi

# --- Steps ---------------------------------------------------------------------------------
PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
SKIPPED=()

pass() { echo "PASS: $1"; PASS_COUNT=$((PASS_COUNT+1)); }
fail() { echo "FAIL: $1"; FAIL_COUNT=$((FAIL_COUNT+1)); }
skip() { echo "SKIP: $1"; SKIP_COUNT=$((SKIP_COUNT+1)); SKIPPED+=("$1"); }

run_step() {
    local name="$1"
    shift
    echo ""
    echo "--- $name ---"
    if "$@"; then
        pass "$name"
    else
        fail "$name"
    fi
}

VENV_DIR=""
cleanup() {
    if [ -n "$VENV_DIR" ] && [ -d "$VENV_DIR" ]; then
        rm -rf "$VENV_DIR"
    fi
}
trap cleanup EXIT

echo "========================================"
echo " Phase 3 verification ($MODE)"
echo "========================================"

# Step 1: source marker guard
run_step "Step 1: source marker guard" ./scripts/check-source-markers.sh

# Step 2: shell test for the Core runner
run_step "Step 2: Core runner shell test" bash tests/shell/test-core-runner.sh

# Step 3: Python suite with all credentials stripped (temp venv on the Mac, system python3 on Linux)
step_python_venv() {
    VENV_DIR=$(mktemp -d)
    python3 -m venv "$VENV_DIR" || return 1
    "$VENV_DIR/bin/pip" install --quiet -r requirements.txt || return 1
    env -u SF_USERNAME -u SF_PASSWORD -u SF_SECURITY_TOKEN -u ASSEMBLYAI_API_KEY -u GEMINI_API_KEY \
        "$VENV_DIR/bin/python" -m unittest discover -s tests/python -t . -v
}
step_python_system() {
    env -u SF_USERNAME -u SF_PASSWORD -u SF_SECURITY_TOKEN -u ASSEMBLYAI_API_KEY -u GEMINI_API_KEY \
        python3 -m unittest discover -s tests/python -t . -v
}
if [ "$MODE" = linux ]; then
    run_step "Step 3: Python suite (system python3)" step_python_system
else
    run_step "Step 3: Python suite in a venv" step_python_venv
fi

# Step 4: Core tests with real swiftc (all tests/*Tests.swift) and the negative control
step_core() {
    ./scripts/test-core.sh || return 1
    if ./scripts/test-core.sh tests/fixtures/AlwaysFailsTests.swift; then
        echo "negative control: AlwaysFailsTests.swift passed, the runner does not detect failures"
        return 1
    fi
    echo "negative control: AlwaysFailsTests.swift failed as expected"
}
if [ "$MODE" = linux ]; then
    skip "Step 4: Core tests and negative control (--linux)"
else
    run_step "Step 4: Core tests and negative control" step_core
fi

# Step 5: app build
step_build() {
    (cd CallBridge && swift build -c release)
}
if [ "$MODE" = linux ]; then
    skip "Step 5: swift build -c release (--linux)"
else
    run_step "Step 5: swift build -c release" step_build
fi

# Step 6: cloudflared installed
step_cloudflared() {
    if command -v cloudflared >/dev/null 2>&1 || test -x /opt/homebrew/bin/cloudflared || test -x /usr/local/bin/cloudflared; then
        echo "cloudflared found"
        return 0
    fi
    echo "cloudflared ontbreekt: brew install cloudflared"
    return 1
}
if [ "$MODE" = linux ]; then
    skip "Step 6: cloudflared installed (--linux)"
else
    run_step "Step 6: cloudflared installed" step_cloudflared
fi

# Step 7: live contract test against the cockpit test routes (needs the paired token)
if [ "$MODE" = linux ]; then
    run_step "Step 7: live test script syntax (bash -n)" bash -n scripts/test-dsh-live.sh
elif [ -n "${DSH_CLIENT_TOKEN:-}" ]; then
    run_step "Step 7: live contract test (test-dsh-live.sh all)" ./scripts/test-dsh-live.sh all
else
    # Single quotes on purpose: the hint must never run `security` and expand the token.
    printf '%s\n' 'Hint: export DSH_CLIENT_TOKEN="$(security find-generic-password -s com.welisa.CallBridge -a DSH_CLIENT_TOKEN -w)"'
    skip "Step 7: live contract test (DSH_CLIENT_TOKEN not set, pair first)"
fi

# Linux only: self-test of the DSH gate against two temp dirs
step_gate_selftest() {
    local bad failed good rc
    bad=$(mktemp -d)
    failed=$(mktemp -d)
    good=$(mktemp -d)
    printf '{"stage":"uploading"}' > "$bad/a.json"
    printf '{"stage":"failed"}' > "$failed/f.json"
    printf '{"stage":"done"}' > "$good/b.json"
    printf '{"stage":"discarded"}' > "$good/c.json"
    rc=0
    if CALLBRIDGE_SESSIONS_DIR="$bad" "$SELF" --dsh-gate >/dev/null; then
        echo "gate passed a dir with an uploading record"
        rc=1
    fi
    if CALLBRIDGE_SESSIONS_DIR="$failed" "$SELF" --dsh-gate >/dev/null; then
        echo "gate passed a dir with a failed record"
        rc=1
    fi
    if ! CALLBRIDGE_SESSIONS_DIR="$good" "$SELF" --dsh-gate | grep -q 'DSH GATE OK'; then
        echo "gate did not pass a dir with only done/discarded records"
        rc=1
    fi
    rm -rf "$bad" "$failed" "$good"
    return $rc
}
if [ "$MODE" = linux ]; then
    run_step "DSH gate self-test" step_gate_selftest
fi

# Summary
echo ""
echo "========================================"
echo " Summary"
echo "========================================"
echo "  PASS: $PASS_COUNT"
echo "  FAIL: $FAIL_COUNT"
echo "  SKIP: $SKIP_COUNT"
for s in "${SKIPPED[@]+"${SKIPPED[@]}"}"; do
    echo "    skipped: $s"
done
echo ""
if [ "$FAIL_COUNT" -eq 0 ]; then
    echo "ALL CHECKS PASSED"
    exit 0
else
    echo "SOME CHECKS FAILED, see output above"
    exit 1
fi

#!/bin/bash
# Phase 1 verification in one command. Runs every check that needs macOS (swiftc, swift build,
# pip) plus the checks that also run on Linux, in the order of .github/workflows/build.yml.
# Each step reports PASS or FAIL; the summary decides the exit code.
#
# Usage:
#   scripts/verify-phase1-mac.sh                  all steps (Kiran's Mac)
#   scripts/verify-phase1-mac.sh --linux          skip the steps that need swiftc or pip,
#                                                 and self-test the sessions gate
#   scripts/verify-phase1-mac.sh --sessions-gate  only the sessions gate (before the real call)
#
# Env:
#   SPLIT_SHA                  overrides the lookup of the split commit by its [phase1-split] marker
#   CALLBRIDGE_SESSIONS_DIR    overrides the sessions directory the gate reads
#
# Read-only towards remotes and Salesforce: no remote git operation, no release, never starts the app.
set -uo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SELF="$PROJECT_ROOT/scripts/verify-phase1-mac.sh"
cd "$PROJECT_ROOT"

MODE=full
case "${1:-}" in
    "") ;;
    --linux) MODE=linux ;;
    --sessions-gate) MODE=gate ;;
    -h|--help)
        sed -n 2,16p "$0"
        exit 0
        ;;
    *)
        echo "usage: $0 [--linux | --sessions-gate]" >&2
        exit 2
        ;;
esac

# --- Sessions gate -------------------------------------------------------------------------
# Guards the switch from the dry-run steps to the real call: no running app, no non-terminal
# and no failed session records. Only reads; never moves or deletes files.
sessions_gate() {
    local dir="${CALLBRIDGE_SESSIONS_DIR:-$HOME/Library/Application Support/com.welisa.CallBridge/sessions}"
    local ok=1
    echo "sessions dir: $dir"
    if command -v pgrep >/dev/null 2>&1; then
        if pgrep -f 'CallBridge.app/Contents/MacOS/CallBridge' >/dev/null 2>&1; then
            echo "FAIL: CallBridge is running, quit it first"
            ok=0
        fi
    else
        echo "note: pgrep not installed, skipping the running-app check"
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
        if stage not in terminal:
            non_terminal += 1
            lines.append(f"{name} {stage}")
print(f"non-terminal sessions: {non_terminal}")
for line in lines:
    print(line)
print(f"failed sessions: {failed}")
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
        echo "SESSIONS GATE OK"
        return 0
    fi
    echo "FAIL: sessions gate"
    return 1
}

if [ "$MODE" = gate ]; then
    sessions_gate
    exit $?
fi

# --- Steps ---------------------------------------------------------------------------------
PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

pass() { echo "PASS: $1"; PASS_COUNT=$((PASS_COUNT+1)); }
fail() { echo "FAIL: $1"; FAIL_COUNT=$((FAIL_COUNT+1)); }
skip() { echo "SKIP: $1 (--linux)"; SKIP_COUNT=$((SKIP_COUNT+1)); }

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
echo " Phase 1 verification ($MODE)"
echo "========================================"

# Step 1: source marker guard
run_step "Step 1: source marker guard" ./scripts/check-source-markers.sh

# Step 2: shell tests for the Core runner and the pure-move check
run_step "Step 2a: Core runner shell test" bash tests/shell/test-core-runner.sh
run_step "Step 2b: pure-move shell test" bash tests/shell/test-pure-move.sh

# Step 3: the main.swift split was a pure move (fdee2c7 -> split commit)
step_pure_move() {
    local split="${SPLIT_SHA:-$(git log --format=%H -n 1 --fixed-strings --grep='[phase1-split]')}"
    if [ -z "$split" ]; then
        echo "split commit [phase1-split] not found"
        return 1
    fi
    echo "split commit: $split"
    ./scripts/check-pure-move.sh \
        --ignore CallBridge/CallBridge/Core/Recorder.swift \
        --ignore CallBridge/CallBridge/Core/SessionState.swift \
        --ignore CallBridge/CallBridge/Core/SessionStore.swift \
        fdee2c7 "$split"
}
if [ "$MODE" = linux ]; then
    skip "Step 3: pure-move check fdee2c7 -> [phase1-split]"
else
    run_step "Step 3: pure-move check fdee2c7 -> [phase1-split]" step_pure_move
fi

# Step 4: Recorder carve-out
run_step "Step 4: Recorder carve-out" python3 scripts/check-recorder-carveout.py

# Step 5: Python suite in a temp venv, with all credentials stripped
step_python() {
    VENV_DIR=$(mktemp -d)
    python3 -m venv "$VENV_DIR" || return 1
    "$VENV_DIR/bin/pip" install --quiet -r requirements.txt || return 1
    env -u SF_USERNAME -u SF_PASSWORD -u SF_SECURITY_TOKEN -u ASSEMBLYAI_API_KEY -u GEMINI_API_KEY \
        "$VENV_DIR/bin/python" -m unittest discover -s tests/python -t . -v
}
if [ "$MODE" = linux ]; then
    skip "Step 5: Python suite in a venv"
else
    run_step "Step 5: Python suite in a venv" step_python
fi

# Step 6: Core tests with real swiftc, negative control, update-channel test
step_core() {
    ./scripts/test-core.sh || return 1
    if ./scripts/test-core.sh tests/fixtures/AlwaysFailsTests.swift; then
        echo "negative control: AlwaysFailsTests.swift passed, the runner does not detect failures"
        return 1
    fi
    echo "negative control: AlwaysFailsTests.swift failed as expected"
    ./scripts/test-update-channel.sh
}
if [ "$MODE" = linux ]; then
    skip "Step 6: Core tests, negative control, update-channel test"
else
    run_step "Step 6: Core tests, negative control, update-channel test" step_core
fi

# Step 7: app build
step_build() {
    (cd CallBridge && swift build -c release)
}
if [ "$MODE" = linux ]; then
    skip "Step 7: swift build -c release"
else
    run_step "Step 7: swift build -c release" step_build
fi

# Linux only: self-test of the sessions gate against two temp dirs
step_gate_selftest() {
    local bad good rc
    bad=$(mktemp -d)
    good=$(mktemp -d)
    printf '{"stage":"transcribing"}' > "$bad/a.json"
    printf '{"stage":"done"}' > "$good/b.json"
    printf '{"stage":"discarded"}' > "$good/c.json"
    rc=0
    if CALLBRIDGE_SESSIONS_DIR="$bad" "$SELF" --sessions-gate >/dev/null; then
        echo "gate passed a dir with a transcribing record"
        rc=1
    fi
    if ! CALLBRIDGE_SESSIONS_DIR="$good" "$SELF" --sessions-gate | grep -q 'SESSIONS GATE OK'; then
        echo "gate did not pass a dir with only done/discarded records"
        rc=1
    fi
    rm -rf "$bad" "$good"
    return $rc
}
if [ "$MODE" = linux ]; then
    run_step "Sessions gate self-test" step_gate_selftest
fi

# Summary
echo ""
echo "========================================"
echo " Summary"
echo "========================================"
echo "  PASS: $PASS_COUNT"
echo "  FAIL: $FAIL_COUNT"
echo "  SKIP: $SKIP_COUNT"
echo ""
if [ "$FAIL_COUNT" -eq 0 ]; then
    echo "ALL CHECKS PASSED"
    exit 0
else
    echo "SOME CHECKS FAILED, see output above"
    exit 1
fi

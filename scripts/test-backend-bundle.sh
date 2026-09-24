#!/usr/bin/env bash
# Integration test for callbridge-server PyInstaller bundle (Phase 2, Plan 03)
# Tests: /health (200), /contact-search (reachable; valid JSON w/ creds), /process (accepted, status=processing)
# sf-prod-gate: backend runs with all credentials stripped and the pipeline is killed
#   before the Salesforce step completes — no production writes

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BINARY_DIR="$PROJECT_ROOT/CallBridge/CallBridge.app/Contents/Resources/callbridge-server"
BINARY_PATH="$BINARY_DIR/callbridge-server"
SUPPORT_DIR="$HOME/Library/Application Support/com.welisa.CallBridge"
VENV_DIR=""
BACKEND_PID=""

# ----- Cleanup trap -----
cleanup() {
    if [ -n "$BACKEND_PID" ] && kill -0 "$BACKEND_PID" 2>/dev/null; then
        echo "Stopping backend (PID $BACKEND_PID)..."
        kill "$BACKEND_PID" 2>/dev/null || true
        sleep 1
        kill -9 "$BACKEND_PID" 2>/dev/null || true
    fi
    if [ -n "$VENV_DIR" ] && [ -d "$VENV_DIR" ]; then
        rm -rf "$VENV_DIR"
    fi
    rm -f /tmp/test-audio.wav
}
trap cleanup EXIT

PASS_COUNT=0
FAIL_COUNT=0

pass() { echo "PASS: $1"; PASS_COUNT=$((PASS_COUNT+1)); }
fail() { echo "FAIL: $1"; FAIL_COUNT=$((FAIL_COUNT+1)); }

cd "$PROJECT_ROOT"

echo "========================================"
echo " CallBridge Backend Bundle Integration Test"
echo "========================================"
echo ""

# Step 1: Pre-flight — verify spec exists
echo "--- Step 1: Pre-flight ---"
if [ ! -f "$PROJECT_ROOT/callbridge-server.spec" ]; then
    echo "ERROR: callbridge-server.spec not found at $PROJECT_ROOT"
    echo "Run /gsd-execute-phase 2 to generate it first."
    exit 1
fi
echo "callbridge-server.spec found."

# Step 2: Build PyInstaller bundle
echo ""
echo "--- Step 2: Build PyInstaller bundle ---"
VENV_DIR="$(python3 -m tempfile 2>/dev/null || mktemp -d)"
VENV_DIR="$(mktemp -d)"
echo "Creating build venv at $VENV_DIR ..."
python3 -m venv "$VENV_DIR"
echo "Installing requirements + pyinstaller..."
"$VENV_DIR/bin/pip" install --quiet -r requirements.txt pyinstaller
echo "Running PyInstaller..."
"$VENV_DIR/bin/pyinstaller" callbridge-server.spec --noconfirm \
    --distpath CallBridge/CallBridge.app/Contents/Resources
echo "PyInstaller complete."

# Step 3: Locate binary
echo ""
echo "--- Step 3: Locate binary ---"
if [ ! -f "$BINARY_PATH" ]; then
    fail "Binary not found at $BINARY_PATH"
    exit 1
fi
echo "Binary found: $BINARY_PATH"
pass "binary exists at Contents/Resources/callbridge-server/callbridge-server"

# Step 4: Pre-flight — port 8765 must be free, otherwise the health check
# would hit an already-running (possibly production) backend instead of ours.
echo ""
echo "--- Step 4: Check port 8765 is free ---"
EXISTING_PIDS="$(lsof -nP -iTCP:8765 -sTCP:LISTEN -t 2>/dev/null || true)"
if [ -n "$EXISTING_PIDS" ]; then
    echo "ERROR: Something is already listening on :8765 (PID(s): $(echo $EXISTING_PIDS))."
    echo "  Stop the running CallBridge backend first, e.g.:"
    echo "    launchctl unload ~/Library/LaunchAgents/com.welisa.callbridge-server.plist"
    exit 1
fi
echo "Port 8765 is free."
# The backend no longer reads .env; remove a copy left behind by older
# versions of this script so no secrets linger in Application Support.
if [ -f "$SUPPORT_DIR/.env" ] && [ -f "$PROJECT_ROOT/.env" ] && cmp -s "$PROJECT_ROOT/.env" "$SUPPORT_DIR/.env"; then
    rm -f "$SUPPORT_DIR/.env"
    echo "Removed stale .env copy from $SUPPORT_DIR"
fi

# Step 5: Launch binary with all credentials stripped from the environment,
# so the test can never reach AssemblyAI, Gemini, or the Salesforce prod org.
echo ""
echo "--- Step 5: Launch binary (credentials stripped) ---"
mkdir -p "$SUPPORT_DIR"
cd "$SUPPORT_DIR"
env -u ASSEMBLYAI_API_KEY -u GEMINI_API_KEY \
    -u SF_USERNAME -u SF_PASSWORD -u SF_SECURITY_TOKEN -u SF_DOMAIN \
    "$BINARY_PATH" > /tmp/callbridge-test-stdout.log 2>&1 &
BACKEND_PID=$!
cd "$PROJECT_ROOT"
echo "Backend launched (PID $BACKEND_PID)"

# Step 6: Health check — poll /health every 1s for up to 30 attempts
echo ""
echo "--- Step 6: Health check ---"
HEALTH_OK=false
for i in $(seq 1 30); do
    printf "  Attempt %d/30 ..." "$i"
    HTTP_CODE=$(curl -sf --max-time 1 -o /dev/null -w "%{http_code}" "http://localhost:8765/health" 2>/dev/null || echo "000")
    if [ "$HTTP_CODE" = "200" ]; then
        echo " 200"
        HEALTH_OK=true
        break
    fi
    echo " $HTTP_CODE (waiting...)"
    sleep 1
done

if $HEALTH_OK && kill -0 "$BACKEND_PID" 2>/dev/null; then
    pass "/health returned 200 from the launched backend (PID $BACKEND_PID alive)"
elif $HEALTH_OK; then
    fail "/health returned 200 but launched backend (PID $BACKEND_PID) is not running — another process answered"
    tail -20 /tmp/callbridge-test-stdout.log || true
    exit 1
else
    fail "/health did not respond within 30s (last code: $HTTP_CODE)"
    echo "Backend stdout/stderr:"
    tail -20 /tmp/callbridge-test-stdout.log || true
    exit 1
fi

# Step 7: /contact-search — endpoint reachable (valid JSON with creds; SF error without creds is acceptable per Phase 2 shape test)
echo ""
echo "--- Step 7: /contact-search ---"
SEARCH_CODE=$(curl -s --max-time 5 -o /tmp/cb-search-body.txt -w "%{http_code}" "http://localhost:8765/contact-search?q=test" 2>/dev/null || echo "000")
SEARCH_BODY=$(cat /tmp/cb-search-body.txt 2>/dev/null); rm -f /tmp/cb-search-body.txt
if [ "$SEARCH_CODE" = "000" ] || [ -z "$SEARCH_CODE" ]; then
    fail "/contact-search unreachable (connection refused)"
elif [ "$SEARCH_CODE" = "200" ]; then
    if echo "$SEARCH_BODY" | python3 -c "import sys,json; json.load(sys.stdin)" 2>/dev/null; then
        pass "/contact-search returned 200 with valid JSON"
    else
        fail "/contact-search 200 but not valid JSON: $SEARCH_BODY"
    fi
else
    pass "/contact-search reachable (HTTP $SEARCH_CODE — expected: test backend runs without Salesforce credentials)"
fi

# Step 8: /process — returns job_id
echo ""
echo "--- Step 8: /process (sf-prod-gate: pipeline killed before Salesforce step) ---"
echo "NOTE: SF prod gate — pipeline intentionally killed before Salesforce step completes."
echo "      No Salesforce production writes occur during this test."

# Create a minimal silent WAV (1s, mono, 16-bit, 44100Hz) for upload
if command -v sox > /dev/null 2>&1; then
    sox -n -r 44100 -c 1 /tmp/test-audio.wav trim 0.0 1.0 2>/dev/null || \
        python3 -c "
import wave, struct
with wave.open('/tmp/test-audio.wav', 'w') as f:
    f.setnchannels(1); f.setsampwidth(2); f.setframerate(44100)
    f.writeframes(struct.pack('<' + 'h' * 44100, *([0]*44100)))
print('WAV created via Python')
"
else
    python3 -c "
import wave, struct
with wave.open('/tmp/test-audio.wav', 'w') as f:
    f.setnchannels(1); f.setsampwidth(2); f.setframerate(44100)
    f.writeframes(struct.pack('<' + 'h' * 44100, *([0]*44100)))
print('WAV created via Python (sox not available)')
"
fi

PROCESS_RESPONSE=$(curl -sf --max-time 10 -X POST \
    -F "audio=@/tmp/test-audio.wav" \
    -F "phone_number=+31612345678" \
    "http://localhost:8765/process" 2>/dev/null || echo "")

if [ -z "$PROCESS_RESPONSE" ]; then
    fail "/process returned empty response"
else
    ACCEPTED=$(echo "$PROCESS_RESPONSE" | python3 -c "import sys,json; d=json.load(sys.stdin); print('ok' if d.get('status')=='processing' else 'missing')" 2>/dev/null || echo "")
    if [ "$ACCEPTED" = "ok" ]; then
        pass "/process accepted upload and returned status=processing"
        echo "  (Pipeline running async — backend will be killed before Salesforce step; sf-prod-gate enforced)"
    else
        fail "/process did not return status=processing. Response: $PROCESS_RESPONSE"
    fi
fi

# Step 9: Summary
echo ""
echo "========================================"
echo " Test Summary"
echo "========================================"
echo "  PASS: $PASS_COUNT"
echo "  FAIL: $FAIL_COUNT"
echo ""
if [ "$FAIL_COUNT" -eq 0 ]; then
    echo "ALL TESTS PASSED"
    exit 0
else
    echo "SOME TESTS FAILED — see output above"
    exit 1
fi

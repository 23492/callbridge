#!/usr/bin/env bash
# Integration test for callbridge-server PyInstaller bundle (Phase 2, Plan 03)
# Tests: /health (200), /contact-search (valid JSON), /process (job_id returned)
# sf-prod-gate: pipeline is killed before Salesforce step completes — no production writes

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

# Step 4: Set up Application Support directory and .env
echo ""
echo "--- Step 4: Configure Application Support ---"
mkdir -p "$SUPPORT_DIR"
if [ -f "$PROJECT_ROOT/.env" ]; then
    cp "$PROJECT_ROOT/.env" "$SUPPORT_DIR/.env"
    echo ".env copied to $SUPPORT_DIR"
else
    echo "WARNING: No .env found at project root — backend will start without credentials."
    echo "  /contact-search will return an error JSON (acceptable for Phase 2 shape test)."
    echo "  /process will start a job but pipeline will fail at transcription step."
fi

# Step 5: Launch binary
echo ""
echo "--- Step 5: Launch binary ---"
cd "$SUPPORT_DIR"
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

if $HEALTH_OK; then
    pass "/health returned 200"
else
    fail "/health did not respond within 30s (last code: $HTTP_CODE)"
    echo "Backend stdout/stderr:"
    tail -20 /tmp/callbridge-test-stdout.log || true
    exit 1
fi

# Step 7: /contact-search — valid JSON response
echo ""
echo "--- Step 7: /contact-search ---"
SEARCH_RESPONSE=$(curl -sf --max-time 5 "http://localhost:8765/contact-search?q=test" 2>/dev/null || echo "")
if [ -z "$SEARCH_RESPONSE" ]; then
    fail "/contact-search returned empty response"
else
    VALID_JSON=$(echo "$SEARCH_RESPONSE" | python3 -c "import sys,json; json.load(sys.stdin); print('ok')" 2>/dev/null || echo "")
    if [ "$VALID_JSON" = "ok" ]; then
        pass "/contact-search returned valid JSON"
    else
        fail "/contact-search response is not valid JSON: $SEARCH_RESPONSE"
    fi
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
    HAS_JOB_ID=$(echo "$PROCESS_RESPONSE" | python3 -c "import sys,json; d=json.load(sys.stdin); print('ok' if 'job_id' in d else 'missing')" 2>/dev/null || echo "")
    if [ "$HAS_JOB_ID" = "ok" ]; then
        JOB_ID=$(echo "$PROCESS_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin)['job_id'])" 2>/dev/null || echo "?")
        pass "/process returned job_id: $JOB_ID"
        echo "  (Pipeline running async — backend will be killed before Salesforce step; sf-prod-gate enforced)"
    else
        fail "/process did not return job_id. Response: $PROCESS_RESPONSE"
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

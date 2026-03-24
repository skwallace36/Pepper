#!/bin/bash
# real-app-smoke.sh — Run Pepper smoke tests against any installed simulator app.
#
# Unlike ci.sh (which builds and installs the test app), this script assumes the
# target app is already installed on a booted simulator. It builds the dylib,
# injects it, and runs a smoke test suite.
#
# Usage:
#   ./scripts/real-app-smoke.sh --bundle-id com.dimillian.IceCubesApp
#   ./scripts/real-app-smoke.sh --bundle-id com.example.app --suite scripts/smoke-custom.json
#   ./scripts/real-app-smoke.sh --bundle-id com.example.app --simulator UDID --port 8790
#
# Environment:
#   SMOKE_TIMEOUT   Server wait timeout in seconds (default: 30)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Defaults
SMOKE_TIMEOUT="${SMOKE_TIMEOUT:-30}"
BUNDLE_ID=""
SUITE_FILE=""
SIM_UDID=""
PORT=""
RESULTS_DIR="$PROJECT_DIR/build/smoke-results"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
DIM='\033[2m'
BOLD='\033[1m'
NC='\033[0m'

step()  { echo -e "\n${BOLD}▸ $1${NC}"; }
pass()  { echo -e "${GREEN}✓${NC} $1"; }
fail()  { echo -e "${RED}✗${NC} $1"; }
info()  { echo -e "${DIM}  $1${NC}"; }

usage() {
    echo "Usage: $0 --bundle-id BUNDLE_ID [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --bundle-id ID     Bundle ID of the app to test (required)"
    echo "  --suite FILE       Smoke test suite JSON file (auto-detected if not set)"
    echo "  --simulator UDID   Simulator UDID (default: first booted simulator)"
    echo "  --port PORT        Pepper port (default: auto from simulator hash)"
    echo "  --timeout SECS     Server wait timeout (default: 30)"
    echo "  --keep-running     Don't terminate the app on exit"
    exit 1
}

# --- Argument parsing ---
KEEP_RUNNING=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --bundle-id)     BUNDLE_ID="$2"; shift 2 ;;
        --suite)         SUITE_FILE="$2"; shift 2 ;;
        --simulator)     SIM_UDID="$2"; shift 2 ;;
        --port)          PORT="$2"; shift 2 ;;
        --timeout)       SMOKE_TIMEOUT="$2"; shift 2 ;;
        --keep-running)  KEEP_RUNNING=1; shift ;;
        -h|--help)       usage ;;
        *)               echo "Unknown option: $1" >&2; usage ;;
    esac
done

if [ -z "$BUNDLE_ID" ]; then
    echo "Error: --bundle-id is required" >&2
    usage
fi

# --- Auto-detect simulator ---
if [ -z "$SIM_UDID" ]; then
    SIM_UDID=$(xcrun simctl list devices booted -j 2>/dev/null | python3 -c "
import json, sys
devs = json.load(sys.stdin)['devices']
ids = [d['udid'] for r in devs.values() for d in r if d['state'] == 'Booted']
print(ids[0] if ids else '')
" 2>/dev/null)
    if [ -z "$SIM_UDID" ]; then
        fail "No booted simulator found. Boot one first: xcrun simctl boot <UDID>"
        exit 1
    fi
fi

# --- Auto-detect port ---
if [ -z "$PORT" ]; then
    PORT=$(echo "$SIM_UDID" | python3 -c "
import sys, hashlib
uid = sys.stdin.read().strip()
print(8770 + int(hashlib.md5(uid.encode()).hexdigest()[:4], 16) % 100)
" 2>/dev/null)
fi

# --- Auto-detect suite file ---
if [ -z "$SUITE_FILE" ]; then
    # Try app-specific suite first, fall back to generic
    APP_SHORT=$(echo "$BUNDLE_ID" | rev | cut -d. -f1 | rev | tr '[:upper:]' '[:lower:]')
    if [ -f "$PROJECT_DIR/scripts/smoke-${APP_SHORT}.json" ]; then
        SUITE_FILE="$PROJECT_DIR/scripts/smoke-${APP_SHORT}.json"
    elif [ -f "$PROJECT_DIR/scripts/smoke-tests.json" ]; then
        SUITE_FILE="$PROJECT_DIR/scripts/smoke-tests.json"
    else
        fail "No smoke test suite found. Provide --suite or create scripts/smoke-tests.json"
        exit 1
    fi
fi

# --- Cleanup trap ---
cleanup() {
    local exit_code=$?

    if [ "$KEEP_RUNNING" -eq 0 ] && [ -n "$SIM_UDID" ]; then
        xcrun simctl terminate "$SIM_UDID" "$BUNDLE_ID" 2>/dev/null || true
        info "App terminated"
    fi

    # Collect logs
    if [ -n "$SIM_UDID" ]; then
        mkdir -p "$RESULTS_DIR"
        xcrun simctl spawn "$SIM_UDID" log show \
            --predicate 'subsystem CONTAINS "pepper"' \
            --last 5m --style compact --info \
            > "$RESULTS_DIR/pepper-log.txt" 2>/dev/null || true
        info "Logs saved to build/smoke-results/pepper-log.txt"
    fi

    if [ $exit_code -eq 0 ]; then
        echo -e "\n${GREEN}${BOLD}Smoke tests passed.${NC}"
    else
        echo -e "\n${RED}${BOLD}Smoke tests failed (exit $exit_code).${NC}"
    fi
    echo "Results: $RESULTS_DIR/"
    exit $exit_code
}
trap cleanup EXIT

# ============================================================
echo -e "${BOLD}pepper real-app smoke — inject → test → report${NC}"
echo -e "${DIM}  App:       $BUNDLE_ID${NC}"
echo -e "${DIM}  Simulator: $SIM_UDID${NC}"
echo -e "${DIM}  Port:      $PORT${NC}"
echo -e "${DIM}  Suite:     $(basename "$SUITE_FILE")${NC}"
# ============================================================

mkdir -p "$RESULTS_DIR"

# --- Step 1: Verify app is installed ---
step "Verifying app is installed"
APP_INFO=$(xcrun simctl listapps "$SIM_UDID" 2>/dev/null | grep -c "$BUNDLE_ID" || true)
if [ "$APP_INFO" -eq 0 ]; then
    fail "App $BUNDLE_ID is not installed on simulator $SIM_UDID"
    info "Install it first, e.g.: xcrun simctl install $SIM_UDID /path/to/App.app"
    exit 1
fi
pass "App is installed"

# --- Step 2: Build dylib ---
step "Building Pepper dylib"
make -C "$PROJECT_DIR" build
DYLIB_PATH="$PROJECT_DIR/build/Pepper.framework/Pepper"
if [ ! -f "$DYLIB_PATH" ]; then
    fail "Pepper.framework not found after build"
    exit 1
fi
pass "Dylib built"

# --- Step 3: Launch with Pepper injected ---
step "Launching app with Pepper injection"
xcrun simctl terminate "$SIM_UDID" "$BUNDLE_ID" 2>/dev/null || true
sleep 1

SIMCTL_CHILD_DYLD_INSERT_LIBRARIES="$DYLIB_PATH" \
SIMCTL_CHILD_PEPPER_PORT="$PORT" \
SIMCTL_CHILD_PEPPER_SIM_UDID="$SIM_UDID" \
SIMCTL_CHILD_PEPPER_ADAPTER="generic" \
SIMCTL_CHILD_PEPPER_SKIP_PERMISSIONS="1" \
    xcrun simctl launch "$SIM_UDID" "$BUNDLE_ID"
pass "App launched on port $PORT"

# --- Step 4: Wait for Pepper server ---
step "Waiting for Pepper server (timeout: ${SMOKE_TIMEOUT}s)"
python3 "$PROJECT_DIR/tools/pepper-ctl" --host 127.0.0.1 --port "$PORT" -v \
    wait-for-server --wait-timeout "$SMOKE_TIMEOUT"
pass "Server ready"

# --- Step 5: Run smoke tests ---
step "Running smoke tests from $(basename "$SUITE_FILE")"
python3 "$PROJECT_DIR/tools/pepper-ctl" --host 127.0.0.1 --port "$PORT" \
    test-report --file "$SUITE_FILE" \
    --format json --output "$RESULTS_DIR/smoke-results.json" \
    --continue-on-error

# --- Step 6: Check results ---
step "Evaluating results"
FAILURES=$(python3 -c "
import json, sys
data = json.load(open('$RESULTS_DIR/smoke-results.json'))
results = data.get('results', data) if isinstance(data, dict) else data
total = len(results)
failed = [r for r in results if r.get('status') != 'pass']
passed = total - len(failed)
for f in failed:
    print(f'  FAIL: {f[\"name\"]} — {f.get(\"message\", \"unknown\")}', file=sys.stderr)
print(f'{passed}/{total} tests passed', file=sys.stderr)
print(len(failed))
" 2>&1)

# The last line is the count; preceding lines are details
FAIL_COUNT=$(echo "$FAILURES" | tail -1)
FAIL_DETAILS=$(echo "$FAILURES" | head -n -1)

if [ -n "$FAIL_DETAILS" ]; then
    echo "$FAIL_DETAILS"
fi

if [ "$FAIL_COUNT" = "0" ]; then
    pass "All smoke tests passed"
else
    fail "$FAIL_COUNT smoke test(s) failed"
    exit 1
fi

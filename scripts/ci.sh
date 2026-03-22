#!/bin/bash
# ci.sh — Full boot → inject → test → teardown cycle for local and CI use.
#
# Usage:
#   ./scripts/ci.sh                    # run full cycle
#   ./scripts/ci.sh --keep-sim         # don't delete simulator on exit
#   ./scripts/ci.sh --simulator UDID   # use existing booted simulator
#
# Environment:
#   CI_DEVICE       Simulator device type (default: "iPhone 16")
#   CI_RUNTIME      Simulator runtime (default: "iOS-18-2")
#   CI_PORT         Pepper port (default: 8765)
#   CI_TIMEOUT      Server wait timeout in seconds (default: 30)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Defaults
CI_DEVICE="${CI_DEVICE:-iPhone 16}"
# Auto-detect latest iOS runtime if not specified
if [ -z "${CI_RUNTIME:-}" ]; then
  CI_RUNTIME=$(xcrun simctl list runtimes -j 2>/dev/null | python3 -c "
import json, sys
runtimes = json.load(sys.stdin).get('runtimes', [])
ios = [r for r in runtimes if r.get('platform') == 'iOS' and r.get('isAvailable', False)]
if ios:
    # Pick latest by version
    ios.sort(key=lambda r: r.get('version', '0'), reverse=True)
    # Convert 'com.apple.CoreSimulator.SimRuntime.iOS-18-4' → 'iOS-18-4'
    ident = ios[0]['identifier'].split('.')[-1]
    print(ident)
else:
    print('iOS-18-2')  # fallback
" 2>/dev/null || echo "iOS-18-2")
fi
CI_PORT="${CI_PORT:-8765}"
CI_TIMEOUT="${CI_TIMEOUT:-30}"
TEST_APP_BUNDLE="com.pepper.testapp"
RESULTS_DIR="$PROJECT_DIR/build/ci-results"

KEEP_SIM=0
USE_EXISTING_SIM=""
SIM_UDID=""
CREATED_SIM=0

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

# --- Argument parsing ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        --keep-sim)       KEEP_SIM=1; shift ;;
        --simulator)      USE_EXISTING_SIM="$2"; shift 2 ;;
        --port)           CI_PORT="$2"; shift 2 ;;
        --timeout)        CI_TIMEOUT="$2"; shift 2 ;;
        *)                echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

# --- Cleanup trap ---
cleanup() {
    local exit_code=$?
    step "Teardown"

    # Terminate the app
    if [ -n "$SIM_UDID" ]; then
        xcrun simctl terminate "$SIM_UDID" "$TEST_APP_BUNDLE" 2>/dev/null || true
        info "App terminated"
    fi

    # Collect logs
    if [ -n "$SIM_UDID" ]; then
        mkdir -p "$RESULTS_DIR"
        xcrun simctl spawn "$SIM_UDID" log show \
            --predicate 'subsystem CONTAINS "pepper"' \
            --last 5m --style compact --info \
            > "$RESULTS_DIR/pepper-log.txt" 2>/dev/null || true
        info "Logs saved to build/ci-results/pepper-log.txt"
    fi

    # Shutdown and delete simulator (unless --keep-sim or using existing)
    if [ "$CREATED_SIM" -eq 1 ] && [ "$KEEP_SIM" -eq 0 ] && [ -n "$SIM_UDID" ]; then
        xcrun simctl shutdown "$SIM_UDID" 2>/dev/null || true
        xcrun simctl delete "$SIM_UDID" 2>/dev/null || true
        info "Simulator $SIM_UDID deleted"
    elif [ -n "$SIM_UDID" ]; then
        info "Simulator $SIM_UDID kept (--keep-sim or pre-existing)"
    fi

    if [ $exit_code -eq 0 ]; then
        echo -e "\n${GREEN}${BOLD}CI passed.${NC}"
    else
        echo -e "\n${RED}${BOLD}CI failed (exit $exit_code).${NC}"
    fi
    echo "Results: $RESULTS_DIR/"
    exit $exit_code
}
trap cleanup EXIT

# ============================================================
echo -e "${BOLD}pepper ci — boot → inject → test → teardown${NC}"
# ============================================================

mkdir -p "$RESULTS_DIR"

# --- Step 1: Simulator ---
if [ -n "$USE_EXISTING_SIM" ]; then
    step "Using existing simulator: $USE_EXISTING_SIM"
    SIM_UDID="$USE_EXISTING_SIM"
else
    step "Creating simulator (${CI_DEVICE}, ${CI_RUNTIME})"
    DEVICE_TYPE="com.apple.CoreSimulator.SimDeviceType.$(echo "$CI_DEVICE" | tr ' ' '-')"
    RUNTIME_ID="com.apple.CoreSimulator.SimRuntime.$CI_RUNTIME"
    SIM_UDID=$(xcrun simctl create "PepperCI" "$DEVICE_TYPE" "$RUNTIME_ID" 2>&1)
    CREATED_SIM=1
    pass "Created simulator: $SIM_UDID"
fi

# --- Step 2: Boot ---
step "Booting simulator"
xcrun simctl boot "$SIM_UDID" 2>/dev/null || true
xcrun simctl bootstatus "$SIM_UDID" -b 2>/dev/null || sleep 3
pass "Simulator booted"

# --- Step 3: Build dylib ---
step "Building Pepper dylib"
make -C "$PROJECT_DIR" build
DYLIB_PATH="$PROJECT_DIR/build/Pepper.framework/Pepper"
if [ ! -f "$DYLIB_PATH" ]; then
    fail "Pepper.framework not found after build"
    exit 1
fi
pass "Dylib built"

# --- Step 4: Build and install test app ---
step "Building and installing test app"
xcodebuild -project "$PROJECT_DIR/test-app/PepperTestApp.xcodeproj" \
    -scheme PepperTestApp -sdk iphonesimulator \
    -destination "id=$SIM_UDID" \
    -configuration Debug build \
    -quiet 2>&1 | tail -5

APP=$(find ~/Library/Developer/Xcode/DerivedData/PepperTestApp-*/Build/Products/Debug-iphonesimulator \
    -name "PepperTestApp.app" -type d 2>/dev/null | head -1)
if [ -z "$APP" ]; then
    fail "Test app build failed — .app not found"
    exit 1
fi

xcrun simctl install "$SIM_UDID" "$APP"
pass "Test app installed"

# --- Step 5: Launch with Pepper injected ---
step "Launching app with Pepper injection"
SIMCTL_CHILD_DYLD_INSERT_LIBRARIES="$DYLIB_PATH" \
SIMCTL_CHILD_PEPPER_PORT="$CI_PORT" \
SIMCTL_CHILD_PEPPER_SIM_UDID="$SIM_UDID" \
SIMCTL_CHILD_PEPPER_ADAPTER="generic" \
SIMCTL_CHILD_PEPPER_SKIP_PERMISSIONS="1" \
    xcrun simctl launch "$SIM_UDID" "$TEST_APP_BUNDLE"
pass "App launched on port $CI_PORT"

# --- Step 6: Wait for Pepper server ---
step "Waiting for Pepper server (timeout: ${CI_TIMEOUT}s)"
python3 "$PROJECT_DIR/tools/pepper-ctl" --host 127.0.0.1 --port "$CI_PORT" \
    wait-for-server --wait-timeout "$CI_TIMEOUT" --verbose
pass "Server ready"

# --- Step 7: Smoke tests ---
step "Running smoke tests"
SMOKE_FILE="$PROJECT_DIR/scripts/smoke-tests.json"
if [ ! -f "$SMOKE_FILE" ]; then
    fail "Smoke test file not found: $SMOKE_FILE"
    exit 1
fi

python3 "$PROJECT_DIR/tools/pepper-ctl" --host 127.0.0.1 --port "$CI_PORT" \
    test-report --file "$SMOKE_FILE" \
    --format json --output "$RESULTS_DIR/smoke-results.json" \
    --continue-on-error

# Check results
FAILURES=$(python3 -c "
import json, sys
data = json.load(open('$RESULTS_DIR/smoke-results.json'))
results = data.get('results', data) if isinstance(data, dict) else data
failed = [r for r in results if r.get('status') != 'pass']
for f in failed:
    print(f'  FAIL: {f[\"name\"]} — {f.get(\"message\", \"unknown\")}', file=sys.stderr)
print(len(failed))
" 2>&1)

# The last line is the count; preceding lines are failure details
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

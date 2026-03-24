#!/bin/bash
# demo.sh — Automated demo walkthrough of Pepper capabilities.
#
# Sets up the PepperTestApp, injects Pepper, and runs through a sequence of
# interactions. Designed to be run while screen-recording for a demo video.
#
# Usage:
#   ./scripts/demo.sh              # full setup + demo
#   ./scripts/demo.sh --skip-build # skip build/install (app already running)
#   ./scripts/demo.sh --step-by-step # pause between steps for commentary
#
# Output is formatted for readability on screen.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
TOOLS_DIR="$PROJECT_DIR/tools"

TEST_APP_BUNDLE="com.pepper.testapp"

# Colors
BOLD='\033[1m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[0;33m'
DIM='\033[2m'
NC='\033[0m'

header() { echo -e "\n${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; echo -e "${BOLD}${CYAN}  $1${NC}"; echo -e "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; }
step()   { echo -e "\n${BOLD}▸ $1${NC}"; }
cmd()    { echo -e "${DIM}\$ $1${NC}"; }
info()   { echo -e "${GREEN}  $1${NC}"; }
pause()  { if [ "$STEP_BY_STEP" -eq 1 ]; then echo -e "\n${YELLOW}  [press enter to continue]${NC}"; read -r; fi; }

SKIP_BUILD=0
STEP_BY_STEP=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --skip-build)    SKIP_BUILD=1; shift ;;
        --step-by-step)  STEP_BY_STEP=1; shift ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

# Detect booted simulator
SIMULATOR_ID=$(xcrun simctl list devices booted -j 2>/dev/null | python3 -c "
import json, sys
devs = json.load(sys.stdin)['devices']
ids = [d['udid'] for r in devs.values() for d in r if d['state'] == 'Booted']
print(ids[0] if ids else '')
" 2>/dev/null)

if [ -z "$SIMULATOR_ID" ]; then
    echo "error: No booted simulator found." >&2
    echo "  Boot one with:  xcrun simctl boot 'iPhone 16'" >&2
    echo "  Then open it:   open -a Simulator" >&2
    exit 1
fi

# Compute port (matches Makefile deterministic hash)
PORT=$(echo "$SIMULATOR_ID" | python3 -c "
import sys, hashlib
uid = sys.stdin.read().strip()
print(8770 + int(hashlib.md5(uid.encode()).hexdigest()[:4], 16) % 100 if uid else 8765)
" 2>/dev/null)

ctl() {
    # Run a pepper-ctl command and print the result
    local label="$1"; shift
    echo -e "${DIM}  → $label${NC}"
    python3 "$TOOLS_DIR/pepper-ctl" --port "$PORT" "$@" 2>&1 | head -40 || true
    echo ""
}

# ============================================================
header "Pepper — iOS Runtime Control Demo"
echo ""
echo -e "  ${DIM}App:       PepperTestApp (${TEST_APP_BUNDLE})${NC}"
echo -e "  ${DIM}Simulator: ${SIMULATOR_ID}${NC}"
echo -e "  ${DIM}Port:      ws://localhost:${PORT}${NC}"
echo ""

# ============================================================
if [ "$SKIP_BUILD" -eq 0 ]; then
    step "1 / 6  Build & inject Pepper"
    echo ""
    cmd "make test-deploy"
    pause
    make -C "$PROJECT_DIR" test-deploy SIMULATOR_ID="$SIMULATOR_ID" PORT="$PORT" --no-print-directory 2>&1 \
        | grep -E '(Building|Installing|Launched|Pepper|error)' | head -20 || true
    info "Pepper injected — control plane at ws://localhost:${PORT}"
else
    step "1 / 6  (skipping build — using running app)"
    # Wait for server
    python3 -c "
import sys, time
sys.path.insert(0, '$TOOLS_DIR')
from pepper_sessions import quick_port_check
for _ in range(20):
    if quick_port_check($PORT, 0.5): break
    time.sleep(0.5)
else:
    print('error: Pepper server not responding on port $PORT', file=sys.stderr)
    sys.exit(1)
print('  Server ready')
" 2>&1
fi

pause

# ============================================================
step "2 / 6  Observe — what's on screen right now?"
echo ""
cmd "pepper-ctl look"
pause
ctl "look" look

# ============================================================
step "3 / 6  Inspect the UI tree"
echo ""
cmd "pepper-ctl raw tree"
pause
ctl "tree" raw tree

# ============================================================
step "4 / 6  Tap the List tab"
echo ""
cmd "pepper-ctl raw tap --label 'List'"
pause
ctl "tap List tab" raw tap --label "List"
sleep 0.5
ctl "look after tap" look

# ============================================================
step "5 / 6  Check console logs & network activity"
echo ""
cmd "pepper-ctl raw console"
pause
ctl "console" raw console
cmd "pepper-ctl raw network"
pause
ctl "network" raw network

# ============================================================
step "6 / 6  Inspect app state"
echo ""
cmd "pepper-ctl raw vars_inspect"
pause
ctl "vars" raw vars_inspect
cmd "pepper-ctl raw screen"
pause
ctl "screen info" raw screen

# ============================================================
header "Demo complete"
echo ""
echo -e "  ${GREEN}Pepper observed and interacted with the app without any source changes.${NC}"
echo ""
echo -e "  ${DIM}Tools used: look, tree, tap, console, network, vars_inspect, screen${NC}"
echo -e "  ${DIM}Control plane: ws://localhost:${PORT}${NC}"
echo ""
echo -e "  ${BOLD}Next steps:${NC}"
echo -e "  ${DIM}  • Try any real app: make deploy BUNDLE_ID=com.example.app${NC}"
echo -e "  ${DIM}  • Connect Claude Code via MCP (.mcp.json already configured)${NC}"
echo -e "  ${DIM}  • Full tool list: make pepper-ctl${NC}"
echo ""

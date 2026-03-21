#!/bin/bash
# Pepper development setup — checks prerequisites, installs deps, sets up hooks.
# Usage: make setup
set -e

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
DIM='\033[2m'
NC='\033[0m'

pass() { echo -e "${GREEN}✓${NC} $1"; }
fail() { echo -e "${RED}✗${NC} $1"; ERRORS=$((ERRORS + 1)); }
warn() { echo -e "${YELLOW}⚠${NC} $1"; }
info() { echo -e "${DIM}$1${NC}"; }

ERRORS=0

echo "pepper setup"
echo "============"
echo ""

# --- Prerequisites ---
echo "Prerequisites"
echo "-------------"

# Xcode
if xcode-select -p &>/dev/null; then
    XCODE_VER=$(xcodebuild -version 2>/dev/null | head -1)
    pass "Xcode: $XCODE_VER"
else
    fail "Xcode not installed — run: xcode-select --install"
fi

# Python 3
if command -v python3 &>/dev/null; then
    PY_VER=$(python3 --version)
    pass "$PY_VER"
else
    fail "Python 3 not found"
fi

# websockets package
if python3 -c "import websockets" 2>/dev/null; then
    pass "Python websockets package"
else
    warn "Python websockets not installed — installing..."
    pip3 install websockets --quiet && pass "Installed websockets" || fail "Could not install websockets"
fi

# Simulator
BOOTED_SIM=$(xcrun simctl list devices booted -j 2>/dev/null | python3 -c "
import json, sys
devs = json.load(sys.stdin)['devices']
booted = [d for r in devs.values() for d in r if d['state'] == 'Booted']
if booted:
    print(f\"{booted[0]['name']} ({booted[0]['udid'][:8]}...)\")
" 2>/dev/null)
if [ -n "$BOOTED_SIM" ]; then
    pass "Simulator booted: $BOOTED_SIM"
else
    warn "No simulator booted — run: open -a Simulator"
fi

echo ""

# --- Environment ---
echo "Environment"
echo "-----------"

if [ -f "$REPO_DIR/.env" ]; then
    pass ".env exists"
    # Check required vars
    if grep -q "APP_BUNDLE_ID=" "$REPO_DIR/.env"; then
        BUNDLE=$(grep "APP_BUNDLE_ID=" "$REPO_DIR/.env" | cut -d= -f2)
        pass "APP_BUNDLE_ID=$BUNDLE"
    else
        fail "APP_BUNDLE_ID not set in .env"
    fi
else
    fail ".env missing — creating from .env.example"
    cp "$REPO_DIR/.env.example" "$REPO_DIR/.env"
    warn "Edit .env with your settings"
fi

echo ""

# --- Git hooks ---
echo "Git hooks"
echo "---------"

HOOK_PATH="$REPO_DIR/.git/hooks/pre-commit"
SCRIPT_PATH="../../scripts/pre-commit"

if [ -L "$HOOK_PATH" ] && [ "$(readlink "$HOOK_PATH")" = "$SCRIPT_PATH" ]; then
    pass "Pre-commit hook installed"
else
    ln -sf "$SCRIPT_PATH" "$HOOK_PATH"
    chmod +x "$HOOK_PATH"
    pass "Pre-commit hook installed (just now)"
fi

echo ""

# --- Build test ---
echo "Build"
echo "-----"

info "Building dylib..."
BUILD_OUTPUT=$(make -C "$REPO_DIR" build 2>&1)
if echo "$BUILD_OUTPUT" | sed 's/\x1b\[[0-9;]*m//g' | grep -q "Built Pepper"; then
    pass "Dylib builds"
else
    fail "Dylib build failed"
    echo "$BUILD_OUTPUT" | grep "error:" | head -5
fi

# Generated docs sync
info "Checking generated docs..."
for gen_script in gen-coverage.py gen-commands.py; do
    name=$(echo "$gen_script" | sed 's/gen-//' | sed 's/\.py//')
    if python3 "$REPO_DIR/scripts/$gen_script" --check 2>/dev/null; then
        pass "${name^^}.md in sync"
    else
        warn "${name^^}.md stale — regenerating..."
        python3 "$REPO_DIR/scripts/$gen_script"
        pass "${name^^}.md regenerated"
    fi
done

echo ""
echo "============"
if [ $ERRORS -gt 0 ]; then
    echo -e "${RED}Setup completed with $ERRORS error(s).${NC}"
    exit 1
fi
echo -e "${GREEN}Setup complete. Ready to develop.${NC}"
echo ""
echo "Quick start:"
echo "  make deploy      Build + inject into running app"
echo "  make test-deploy  Build test app + inject Pepper"
echo "  make help         All available targets"

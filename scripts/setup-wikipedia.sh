#!/bin/bash
# setup-wikipedia.sh — Clone, build, and install Wikipedia iOS on the booted simulator.
#
# Usage:
#   ./scripts/setup-wikipedia.sh               # clone + build + install
#   ./scripts/setup-wikipedia.sh --clean        # remove cached clone and rebuild
#   ./scripts/setup-wikipedia.sh --install-only # skip build, just install cached .app
#
# Prerequisites:
#   - Xcode with iOS Simulator SDK
#   - A booted iOS simulator
#   - CocoaPods (gem install cocoapods) — Wikipedia iOS uses Pods
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
EXTERNAL_DIR="$PROJECT_DIR/build/external"
WIKI_DIR="$EXTERNAL_DIR/wikipedia-ios"
WIKI_REPO="https://github.com/wikimedia/wikipedia-ios.git"
WIKI_BUNDLE_ID="org.wikimedia.wikipedia"

# Detect booted simulator
SIMULATOR_ID="${SIMULATOR_ID:-$(xcrun simctl list devices booted -j 2>/dev/null | python3 -c "
import json, sys
devs = json.load(sys.stdin)['devices']
ids = [d['udid'] for r in devs.values() for d in r if d['state'] == 'Booted']
print(ids[0] if ids else '')
" 2>/dev/null)}"

if [ -z "$SIMULATOR_ID" ]; then
    echo "error: No booted simulator found. Boot one first:" >&2
    echo "  xcrun simctl boot 'iPhone 16'" >&2
    exit 1
fi

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

info()    { echo -e "${BLUE}wiki:${NC} $*"; }
success() { echo -e "${GREEN}wiki:${NC} $*"; }
error()   { echo -e "${RED}wiki:${NC} $*" >&2; }

# --- Options ---
CLEAN=0
INSTALL_ONLY=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --clean)        CLEAN=1; shift ;;
        --install-only) INSTALL_ONLY=1; shift ;;
        *)              echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

if [ "$CLEAN" -eq 1 ]; then
    info "Cleaning cached Wikipedia build..."
    rm -rf "$WIKI_DIR"
fi

# --- Step 1: Clone ---
if [ ! -d "$WIKI_DIR" ]; then
    info "Cloning wikipedia-ios (shallow)..."
    mkdir -p "$EXTERNAL_DIR"
    git clone --depth 1 "$WIKI_REPO" "$WIKI_DIR"
    success "Cloned to $WIKI_DIR"
else
    info "Using cached clone at $WIKI_DIR"
fi

if [ "$INSTALL_ONLY" -eq 1 ]; then
    # Skip build, jump to install
    APP=$(find ~/Library/Developer/Xcode/DerivedData/Wikipedia-*/Build/Products/Debug-iphonesimulator \
        -name "Wikipedia.app" -type d 2>/dev/null | head -1)
    if [ -z "$APP" ]; then
        error "No cached Wikipedia.app found. Run without --install-only first."
        exit 1
    fi
    info "Installing cached build on simulator $SIMULATOR_ID..."
    xcrun simctl install "$SIMULATOR_ID" "$APP"
    success "Wikipedia installed. Bundle ID: $WIKI_BUNDLE_ID"
    exit 0
fi

cd "$WIKI_DIR"

# --- Step 2: Install dependencies ---
if [ -f "Podfile" ] && ! [ -d "Pods" ]; then
    info "Installing CocoaPods dependencies..."
    if ! command -v pod &>/dev/null; then
        error "CocoaPods not found. Install with: gem install cocoapods"
        exit 1
    fi
    pod install --repo-update
    success "Pods installed"
elif [ -d "Pods" ]; then
    info "Pods already installed"
fi

# --- Step 3: Build ---
info "Building Wikipedia for simulator (this may take a few minutes)..."

# Wikipedia uses a workspace when Pods are present
if [ -f "Wikipedia.xcworkspace/contents.xcworkspacedata" ]; then
    BUILD_TARGET="-workspace Wikipedia.xcworkspace"
else
    BUILD_TARGET="-project Wikipedia.xcodeproj"
fi

# Build for simulator — use CODE_SIGNING_ALLOWED=NO to skip signing
xcodebuild $BUILD_TARGET \
    -scheme Wikipedia \
    -sdk iphonesimulator \
    -destination "id=$SIMULATOR_ID" \
    -configuration Debug \
    CODE_SIGNING_ALLOWED=NO \
    build \
    2>&1 | tail -20

# --- Step 4: Find and install ---
APP=$(find ~/Library/Developer/Xcode/DerivedData/Wikipedia-*/Build/Products/Debug-iphonesimulator \
    -name "Wikipedia.app" -type d 2>/dev/null | head -1)

if [ -z "$APP" ]; then
    error "Build failed — Wikipedia.app not found in DerivedData."
    error "Check the build output above for errors."
    exit 1
fi

info "Installing on simulator $SIMULATOR_ID..."
xcrun simctl install "$SIMULATOR_ID" "$APP"

success "Wikipedia iOS installed successfully."
echo ""
echo -e "${BOLD}Next steps:${NC}"
echo "  1. Deploy Pepper into Wikipedia:"
echo "     make deploy APP_BUNDLE_ID=$WIKI_BUNDLE_ID"
echo ""
echo "  2. Or use the shortcut:"
echo "     make wikipedia-deploy"
echo ""
echo "  3. Run smoke tests:"
echo "     make wikipedia-smoke"

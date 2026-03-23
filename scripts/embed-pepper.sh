#!/bin/bash
set -euo pipefail

# Embed Pepper.xcframework into an Xcode project for on-device use.
#
# This script:
#   1. Builds Pepper.xcframework if it doesn't exist
#   2. Copies it into the Xcode project directory
#   3. Prints Xcode configuration instructions
#
# Usage:
#   ./scripts/embed-pepper.sh /path/to/YourApp.xcodeproj
#   ./scripts/embed-pepper.sh /path/to/YourApp.xcodeproj --rebuild

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
WORKTREE_ROOT=$(git -C "$PROJECT_DIR" rev-parse --show-toplevel 2>/dev/null || echo "$PROJECT_DIR")
XCF_PATH="$WORKTREE_ROOT/build/Pepper.xcframework"

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

info()    { echo -e "${BLUE}embed:${NC} $*"; }
success() { echo -e "${GREEN}embed:${NC} $*"; }
error()   { echo -e "${RED}embed:${NC} $*" >&2; }

usage() {
    echo "Usage: $0 <path/to/YourApp.xcodeproj> [--rebuild]"
    echo ""
    echo "Options:"
    echo "  --rebuild    Force rebuild of Pepper.xcframework"
    exit 1
}

# --- Parse args ---
XCODEPROJ=""
REBUILD=""
for arg in "$@"; do
    case "$arg" in
        --rebuild) REBUILD=1 ;;
        -h|--help) usage ;;
        *.xcodeproj) XCODEPROJ="$arg" ;;
        *) error "Unknown argument: $arg"; usage ;;
    esac
done

if [ -z "$XCODEPROJ" ]; then
    error "Missing Xcode project path"
    usage
fi

if [ ! -d "$XCODEPROJ" ]; then
    error "Xcode project not found: $XCODEPROJ"
    exit 1
fi

# --- Build xcframework if needed ---
if [ -n "$REBUILD" ] || [ ! -d "$XCF_PATH" ]; then
    info "Building Pepper.xcframework..."
    bash "$PROJECT_DIR/tools/build-xcframework.sh" ${REBUILD:+--clean}
fi

# --- Copy into project directory ---
DEST_DIR="$(dirname "$XCODEPROJ")"
DEST_XCF="$DEST_DIR/Pepper.xcframework"

if [ -d "$DEST_XCF" ]; then
    info "Removing existing Pepper.xcframework..."
    rm -rf "$DEST_XCF"
fi

cp -R "$XCF_PATH" "$DEST_XCF"
success "Copied Pepper.xcframework → $DEST_XCF"

# --- Print Xcode setup instructions ---
echo ""
echo -e "${BOLD}=== Xcode Setup Instructions ===${NC}"
echo ""
echo "  1. Open $(basename "$XCODEPROJ") in Xcode"
echo ""
echo "  2. Add the framework:"
echo "     • Select your app target → General → Frameworks, Libraries, and Embedded Content"
echo "     • Click '+' → Add Other → Add Files → select Pepper.xcframework"
echo "     • Set embed mode to \"Embed & Sign\""
echo ""
echo "  3. No code changes needed — Pepper starts automatically via"
echo "     __attribute__((constructor)) when the framework loads."
echo "     Default WebSocket port: 8765"
echo ""
echo "  4. To set a custom port, add to your scheme's environment variables:"
echo "     • Product → Scheme → Edit Scheme → Run → Arguments → Environment Variables"
echo "     • Add: PEPPER_PORT = <your port>"
echo ""
echo "  5. Connect from your Mac (device must be on same WiFi network):"
echo "     • Find the device IP: Settings → Wi-Fi → tap (i) on your network"
echo "     • Connect: pepper-ctl --host <device-ip> --port 8765 ping"
echo ""
echo -e "${BOLD}=== Local Network (required for iOS 14+) ===${NC}"
echo ""
echo "  If your app doesn't already have Local Network permission:"
echo "  • Add to Info.plist:"
echo "    - NSLocalNetworkUsageDescription: \"Pepper debug server\""
echo "    - NSBonjourServices: [\"_pepper._tcp\"]"
echo ""
success "Done. Build and run your app to start Pepper."

#!/bin/bash
set -euo pipefail

# scripts/submit-mcp-directories.sh — submit Pepper to MCP directories
#
# Usage:
#   submit-mcp-directories.sh [directory...]
#
# Directories:
#   awesome-wong2      awesome-mcp-servers (wong2/awesome-mcp-servers)
#   awesome-punkpeye   awesome-mcp-servers (punkpeye/awesome-mcp-servers)
#   mcp-registry       Official MCP server registry (modelcontextprotocol/servers)
#   mcp-so             mcp.so directory
#   glama              glama.ai MCP directory
#   pulsemcp           pulsemcp.com directory
#   cline              Cline marketplace
#   all                Submit to all directories
#
# Requires: gh (GitHub CLI), jq

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_URL="https://github.com/skwallace36/Pepper"
METADATA="$REPO_ROOT/tools/mcp-registry.json"

# ── Descriptions used across submissions ──────────────────────────────────────

SHORT_DESC="Runtime control for iOS simulator apps via MCP. 64 tools for navigation, debugging, state inspection, and automation — no source modifications needed."

LONG_DESC="Pepper is a dylib injected into iOS simulator apps at launch via DYLD_INSERT_LIBRARIES. It starts a WebSocket server inside the app process and exposes 64 MCP tools for:

- **Navigation**: tap, scroll, swipe, input text, navigate, dismiss
- **Observation**: look (full UI hierarchy), screen capture, find, tree
- **Debugging**: console logs, network traffic, heap inspection, crash logs, layers, animations
- **State**: SwiftUI vars, NSUserDefaults, keychain, clipboard, cookies, feature flags
- **System**: push notifications, orientation, locale, method hooking
- **Build/Deploy**: build, deploy, iterate cycle from within the agent

No source patches required. Works with any iOS simulator app. Supports both SwiftUI and UIKit via a single HID injection pipeline."

AWESOME_ENTRY="- [Pepper](https://github.com/skwallace36/Pepper) - Runtime control for iOS simulator apps. 64 MCP tools for navigation, debugging, state inspection, and automation via dylib injection."

# ── Helpers ───────────────────────────────────────────────────────────────────

red()   { printf '\033[0;31m%s\033[0m\n' "$*"; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
blue()  { printf '\033[0;34m%s\033[0m\n' "$*"; }
bold()  { printf '\033[1m%s\033[0m\n' "$*"; }

check_deps() {
    for cmd in gh jq; do
        if ! command -v "$cmd" &>/dev/null; then
            red "Error: $cmd is required but not installed."
            exit 1
        fi
    done
}

# ── awesome-mcp-servers (wong2) ───────────────────────────────────────────────

submit_awesome_wong2() {
    bold "=== awesome-mcp-servers (wong2) ==="
    local UPSTREAM="wong2/awesome-mcp-servers"

    echo "Forking $UPSTREAM..."
    gh repo fork "$UPSTREAM" --clone=false 2>/dev/null || true

    local FORK
    FORK="$(gh api user --jq .login)/$( echo "$UPSTREAM" | cut -d/ -f2 )"
    local TMPDIR
    TMPDIR="$(mktemp -d)"

    echo "Cloning fork to $TMPDIR..."
    gh repo clone "$FORK" "$TMPDIR" -- --depth=1 2>/dev/null

    pushd "$TMPDIR" >/dev/null

    git remote add upstream "https://github.com/$UPSTREAM.git" 2>/dev/null || true
    git fetch upstream --depth=1 2>/dev/null
    git checkout -b add-pepper upstream/main 2>/dev/null || git checkout -b add-pepper

    # Find the right section and append
    local README="$TMPDIR/README.md"
    if [ -f "$README" ]; then
        # Look for a mobile/iOS section or a general tools section
        if grep -q "Pepper" "$README" 2>/dev/null; then
            green "Pepper already listed in $UPSTREAM — skipping."
            popd >/dev/null
            rm -rf "$TMPDIR"
            return 0
        fi

        # Append to the end of the server list (before any footer/license section)
        echo "" >> "$README"
        echo "$AWESOME_ENTRY" >> "$README"

        git add README.md
        git commit -m "Add Pepper — iOS simulator runtime control via MCP"
        git push origin add-pepper --force-with-lease

        echo "Opening PR..."
        gh pr create \
            --repo "$UPSTREAM" \
            --title "Add Pepper — iOS simulator runtime control via MCP" \
            --body "$(cat <<'PREOF'
## What is Pepper?

Pepper is a dylib injected into iOS simulator apps at launch. It starts a WebSocket server inside the app process and exposes 64 MCP tools for navigation, debugging, state inspection, and automation — no source modifications needed.

**Repository**: https://github.com/skwallace36/Pepper

### Tool categories (64 tools)
- **Navigation**: look, tap, scroll, swipe, input_text, navigate, back, dismiss
- **Debugging**: console, network, heap, crash_log, layers, animations, lifecycle
- **State**: vars_inspect, defaults, clipboard, keychain, cookies, flags
- **System**: push, orientation, locale, hook, find, tree, highlight
- **Build**: build, deploy, iterate

### Why it belongs here
Only in-process iOS runtime inspector exposed via MCP. External tools (Appium, Maestro) can't access heap, network interception, keychain, or SwiftUI state variables.
PREOF
            )" 2>&1 && green "PR opened on $UPSTREAM" || red "Failed to open PR on $UPSTREAM"
    fi

    popd >/dev/null
    rm -rf "$TMPDIR"
}

# ── awesome-mcp-servers (punkpeye) ────────────────────────────────────────────

submit_awesome_punkpeye() {
    bold "=== awesome-mcp-servers (punkpeye) ==="
    local UPSTREAM="punkpeye/awesome-mcp-servers"

    echo "Forking $UPSTREAM..."
    gh repo fork "$UPSTREAM" --clone=false 2>/dev/null || true

    local FORK
    FORK="$(gh api user --jq .login)/$(echo "$UPSTREAM" | cut -d/ -f2)"
    local TMPDIR
    TMPDIR="$(mktemp -d)"

    echo "Cloning fork to $TMPDIR..."
    gh repo clone "$FORK" "$TMPDIR" -- --depth=1 2>/dev/null

    pushd "$TMPDIR" >/dev/null

    git remote add upstream "https://github.com/$UPSTREAM.git" 2>/dev/null || true
    git fetch upstream --depth=1 2>/dev/null
    git checkout -b add-pepper upstream/main 2>/dev/null || git checkout -b add-pepper

    local README="$TMPDIR/README.md"
    if [ -f "$README" ]; then
        if grep -q "Pepper" "$README" 2>/dev/null; then
            green "Pepper already listed in $UPSTREAM — skipping."
            popd >/dev/null
            rm -rf "$TMPDIR"
            return 0
        fi

        echo "" >> "$README"
        echo "$AWESOME_ENTRY" >> "$README"

        git add README.md
        git commit -m "Add Pepper — iOS simulator runtime control via MCP"
        git push origin add-pepper --force-with-lease

        echo "Opening PR..."
        gh pr create \
            --repo "$UPSTREAM" \
            --title "Add Pepper — iOS simulator runtime control via MCP" \
            --body "$(cat <<'PREOF'
## What is Pepper?

Pepper is a dylib injected into iOS simulator apps at launch. It starts a WebSocket server inside the app process and exposes 64 MCP tools for navigation, debugging, state inspection, and automation — no source modifications needed.

**Repository**: https://github.com/skwallace36/Pepper

### Tool categories (64 tools)
- **Navigation**: look, tap, scroll, swipe, input_text, navigate, back, dismiss
- **Debugging**: console, network, heap, crash_log, layers, animations, lifecycle
- **State**: vars_inspect, defaults, clipboard, keychain, cookies, flags
- **System**: push, orientation, locale, hook, find, tree, highlight
- **Build**: build, deploy, iterate

### Why it belongs here
Only in-process iOS runtime inspector exposed via MCP. External tools (Appium, Maestro) can't access heap, network interception, keychain, or SwiftUI state variables.
PREOF
            )" 2>&1 && green "PR opened on $UPSTREAM" || red "Failed to open PR on $UPSTREAM"
    fi

    popd >/dev/null
    rm -rf "$TMPDIR"
}

# ── Official MCP registry ────────────────────────────────────────────────────

submit_mcp_registry() {
    bold "=== Official MCP Server Registry ==="
    local UPSTREAM="modelcontextprotocol/servers"

    echo ""
    blue "The official MCP servers registry is at: https://github.com/$UPSTREAM"
    echo ""
    echo "To submit, open an issue or PR at:"
    echo "  https://github.com/$UPSTREAM/issues/new"
    echo ""
    bold "Suggested issue title:"
    echo "  Add Pepper — iOS simulator runtime control MCP server"
    echo ""
    bold "Suggested issue body:"
    cat <<'EOF'
## Server: Pepper

**Repository**: https://github.com/skwallace36/Pepper
**Transport**: stdio
**Language**: Python

### Description
Pepper is a dylib injected into iOS simulator apps at launch via DYLD_INSERT_LIBRARIES. It starts a WebSocket server inside the app process and exposes 64 MCP tools for navigation, debugging, state inspection, and automation — no source modifications needed.

### Installation
```bash
git clone https://github.com/skwallace36/Pepper
cd Pepper
make setup
```

### MCP Configuration
```json
{
  "mcpServers": {
    "pepper": {
      "command": "./.venv/bin/python3",
      "args": ["./tools/pepper-mcp"],
      "env": { "PYTHONUNBUFFERED": "1" }
    }
  }
}
```

### Tools (46)
Navigation (13): look, tap, scroll, swipe, gesture, input_text, toggle, navigate, back, dismiss, dismiss_keyboard, dialog, screen
Debug (8): layers, console, network, timeline, crash_log, animations, lifecycle, heap
State (5): vars_inspect, defaults, clipboard, keychain, cookies
System (13): push, status, highlight, orientation, locale, gesture, hook, find, flags, dialog, toggle, read_element, tree
Recording (1): record
Simulator (2): raw, simulator
Build (4): build, build_device, deploy, iterate

### What makes it unique
Only in-process iOS runtime inspector exposed via MCP. Provides deep access to heap, network traffic, console, keychain, layers, lifecycle, and SwiftUI state — capabilities that external tools (Appium MCP, Maestro, etc.) cannot match.
EOF
    echo ""
    green "Copy the above and submit at: https://github.com/$UPSTREAM/issues/new"
}

# ── mcp.so ────────────────────────────────────────────────────────────────────

submit_mcp_so() {
    bold "=== mcp.so ==="
    echo ""
    blue "Submit at: https://mcp.so/submit"
    echo ""
    bold "Submission details:"
    echo "  Name:        Pepper"
    echo "  URL:         $REPO_URL"
    echo "  Description: $SHORT_DESC"
    echo "  Category:    Mobile Development / Testing"
    echo "  Tags:        ios, simulator, mobile, testing, automation, debugging"
    echo ""
    green "Open https://mcp.so/submit and fill in the above details."
}

# ── Glama ─────────────────────────────────────────────────────────────────────

submit_glama() {
    bold "=== Glama ==="
    echo ""
    blue "Submit at: https://glama.ai/mcp/servers/submit"
    echo ""
    bold "Submission details:"
    echo "  GitHub URL:  $REPO_URL"
    echo "  Name:        Pepper"
    echo "  Description: $SHORT_DESC"
    echo "  Category:    Development Tools"
    echo ""
    green "Open https://glama.ai/mcp/servers/submit and paste the GitHub URL."
}

# ── PulseMCP ──────────────────────────────────────────────────────────────────

submit_pulsemcp() {
    bold "=== PulseMCP ==="
    echo ""
    blue "Submit at: https://www.pulsemcp.com/submit"
    echo ""
    bold "Submission details:"
    echo "  Name:        Pepper"
    echo "  URL:         $REPO_URL"
    echo "  Description: $SHORT_DESC"
    echo "  Category:    Mobile Development"
    echo ""
    green "Open https://www.pulsemcp.com/submit and fill in the above details."
}

# ── Cline Marketplace ────────────────────────────────────────────────────────

submit_cline() {
    bold "=== Cline Marketplace ==="
    echo ""
    blue "Submit at: https://github.com/cline/cline/wiki/MCP-Servers"
    echo ""
    echo "Cline discovers MCP servers from the community. To submit:"
    echo "  1. Ensure the repo README has clear installation instructions"
    echo "  2. Add MCP config example to README (already in tools/mcp-registry.json)"
    echo "  3. Submit via Cline's MCP server submission process"
    echo ""
    bold "Suggested entry:"
    echo "$AWESOME_ENTRY"
    echo ""
    green "Check https://github.com/cline/cline for current submission process."
}

# ── Main ──────────────────────────────────────────────────────────────────────

usage() {
    echo "Usage: $0 [directory...]"
    echo ""
    echo "Directories:"
    echo "  awesome-wong2      wong2/awesome-mcp-servers (opens PR)"
    echo "  awesome-punkpeye   punkpeye/awesome-mcp-servers (opens PR)"
    echo "  mcp-registry       Official MCP server registry (prints submission)"
    echo "  mcp-so             mcp.so (prints submission URL)"
    echo "  glama              glama.ai (prints submission URL)"
    echo "  pulsemcp           pulsemcp.com (prints submission URL)"
    echo "  cline              Cline marketplace (prints submission info)"
    echo "  all                Submit to all directories"
    echo ""
    echo "GitHub-based directories (awesome-*) will fork, add entry, and open a PR."
    echo "Web-based directories print pre-formatted submission content and URLs."
}

main() {
    check_deps

    if [ $# -eq 0 ]; then
        usage
        exit 0
    fi

    local targets=("$@")

    # Expand 'all'
    if [[ " ${targets[*]} " == *" all "* ]]; then
        targets=(awesome-wong2 awesome-punkpeye mcp-registry mcp-so glama pulsemcp cline)
    fi

    for target in "${targets[@]}"; do
        echo ""
        case "$target" in
            awesome-wong2)    submit_awesome_wong2 ;;
            awesome-punkpeye) submit_awesome_punkpeye ;;
            mcp-registry)     submit_mcp_registry ;;
            mcp-so)           submit_mcp_so ;;
            glama)            submit_glama ;;
            pulsemcp)         submit_pulsemcp ;;
            cline)            submit_cline ;;
            *)
                red "Unknown directory: $target"
                usage
                exit 1
                ;;
        esac
        echo ""
    done

    bold "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    green "Done! Server metadata is in tools/mcp-registry.json"
}

main "$@"

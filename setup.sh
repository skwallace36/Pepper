#!/bin/bash
# Pepper setup — run once on a new machine, re-run to update.
# Also installs into target app repos (pass paths as args).
#
# Usage:
#   ./setup.sh                              # pepper only
#   ./setup.sh ~/Developer/ios              # pepper + install into ios repo
#   ./setup.sh ~/Developer/ios ~/other/repo # pepper + multiple repos
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PYTHON_PATH=""

echo "pepper setup"
echo "============"
echo ""

# 1. Check Xcode CLI tools
if ! xcode-select -p &>/dev/null; then
    echo "❌ Xcode Command Line Tools not installed."
    echo "   Run: xcode-select --install"
    exit 1
fi
echo "✓ Xcode CLI tools"

# 2. Find Python 3.10+ (required for MCP SDK)
for candidate in python3.13 python3.12 python3.11 python3.10; do
    if command -v "$candidate" &>/dev/null; then
        PYTHON_PATH="$(command -v "$candidate")"
        break
    fi
done

if [ -z "$PYTHON_PATH" ]; then
    if command -v python3 &>/dev/null; then
        PY_VER=$(python3 -c "import sys; print(sys.version_info.minor)")
        if [ "$PY_VER" -ge 10 ]; then
            PYTHON_PATH="$(command -v python3)"
        fi
    fi
fi

if [ -z "$PYTHON_PATH" ]; then
    echo "❌ Python 3.10+ not found. Install with: brew install python@3.11"
    exit 1
fi
echo "✓ Python: $($PYTHON_PATH --version) ($PYTHON_PATH)"

# 3. Install Python deps into local venv (never touches global/user packages)
VENV_DIR="$SCRIPT_DIR/.venv"
echo ""
if [ ! -d "$VENV_DIR" ]; then
    echo "Creating virtual environment..."
    $PYTHON_PATH -m venv "$VENV_DIR"
fi
VENV_PYTHON="$VENV_DIR/bin/python3"
echo "Installing Python dependencies (into .venv)..."
"$VENV_PYTHON" -m pip install -r "$SCRIPT_DIR/requirements.txt" -q 2>/dev/null || {
    echo "❌ Failed to install Python deps. Try manually:"
    echo "   $VENV_PYTHON -m pip install mcp websockets"
    exit 1
}
echo "✓ Python deps installed (in $VENV_DIR)"
PYTHON_PATH="$VENV_PYTHON"

# 4. Build dylib
echo ""
echo "Building Pepper dylib..."
make -C "$SCRIPT_DIR" build
echo "✓ Dylib built"

# 5. Skills — stay in repo, no global install needed
echo ""
echo "✓ Skills available in skills/ (loaded by Claude Code from project root)"

# 6. Install git hooks
echo ""
HOOK_SRC="$SCRIPT_DIR/scripts/pre-commit"
HOOK_DST="$SCRIPT_DIR/.git/hooks/pre-commit"
if [ -d "$SCRIPT_DIR/.git" ]; then
    if [ -L "$HOOK_DST" ] && [ "$(readlink "$HOOK_DST")" = "$HOOK_SRC" ]; then
        echo "✓ pre-commit hook already installed"
    else
        ln -sf "$HOOK_SRC" "$HOOK_DST"
        echo "✓ pre-commit hook installed"
    fi
fi

# 7. Install into target app repos
install_into_repo() {
    local REPO_DIR="$1"
    local REPO_NAME="$(basename "$REPO_DIR")"

    echo ""
    echo "--- Installing into $REPO_NAME ---"

    if [ ! -d "$REPO_DIR/.git" ]; then
        echo "  ⚠ Not a git repo, skipping: $REPO_DIR"
        return
    fi

    # .mcp.json — Pepper MCP server config (merge, don't overwrite)
    local MCP_JSON="$REPO_DIR/.mcp.json"
    if [ -f "$MCP_JSON" ]; then
        if grep -q '"pepper"' "$MCP_JSON" 2>/dev/null; then
            echo "  ✓ .mcp.json already has pepper entry"
        else
            echo "  ⚠ .mcp.json exists but doesn't have pepper. Add manually:"
            echo "    \"pepper\": {\"command\": \"$PYTHON_PATH\", \"args\": [\"$SCRIPT_DIR/tools/pepper-mcp\"], \"env\": {\"PYTHONUNBUFFERED\": \"1\"}}"
        fi
    else
        cat > "$MCP_JSON" << MCPEOF
{
  "mcpServers": {
    "pepper": {
      "command": "$PYTHON_PATH",
      "args": ["$SCRIPT_DIR/tools/pepper-mcp"],
      "env": {
        "PYTHONUNBUFFERED": "1"
      }
    }
  }
}
MCPEOF
        echo "  ✓ .mcp.json created (Pepper MCP server)"
    fi

    # Rules — Pepper instructions loaded by Claude Code
    local RULES_DIR="$REPO_DIR/.claude/rules"
    mkdir -p "$RULES_DIR"
    local RULES_SRC="$SCRIPT_DIR/rules/pepper.md"
    local RULES_DST="$RULES_DIR/pepper.md"
    if [ -L "$RULES_DST" ] && [ "$(readlink "$RULES_DST")" = "$RULES_SRC" ]; then
        echo "  ✓ .claude/rules/pepper.md already symlinked"
    else
        rm -f "$RULES_DST"
        ln -s "$RULES_SRC" "$RULES_DST"
        echo "  ✓ .claude/rules/pepper.md symlinked"
    fi

    # Scripts — xcodebuild wrapper + hook
    local SCRIPTS_DIR="$REPO_DIR/.claude/scripts"
    mkdir -p "$SCRIPTS_DIR"

    # Symlink xcodebuild wrapper
    local XCB_SRC="$SCRIPT_DIR/scripts/xcodebuild.sh"
    local XCB_DST="$SCRIPTS_DIR/xcodebuild.sh"
    if [ -L "$XCB_DST" ] && [ "$(readlink "$XCB_DST")" = "$XCB_SRC" ]; then
        echo "  ✓ xcodebuild.sh already symlinked"
    else
        rm -f "$XCB_DST"
        ln -s "$XCB_SRC" "$XCB_DST"
        echo "  ✓ xcodebuild.sh symlinked"
    fi

    # Symlink check hook
    local HOOK_SRC="$SCRIPT_DIR/scripts/check-xcodebuild.sh"
    local HOOK_DST="$SCRIPTS_DIR/check-xcodebuild.sh"
    if [ -L "$HOOK_DST" ] && [ "$(readlink "$HOOK_DST")" = "$HOOK_SRC" ]; then
        echo "  ✓ check-xcodebuild.sh already symlinked"
    else
        rm -f "$HOOK_DST"
        ln -s "$HOOK_SRC" "$HOOK_DST"
        echo "  ✓ check-xcodebuild.sh symlinked"
    fi

    echo "  ✓ $REPO_NAME ready"
}

# Install into any repos passed as args
for repo in "$@"; do
    if [ -d "$repo" ]; then
        install_into_repo "$repo"
    else
        echo ""
        echo "⚠ Directory not found: $repo"
    fi
done

# 7. Summary
echo ""
echo "============"
echo "Setup complete."
echo ""
echo "Next steps:"
echo "  1. Copy .env.example to .env and fill in your scheme/bundle ID"
echo "  2. Set ADAPTER_PATH in .env if using an app adapter"
echo "  3. Boot a simulator and deploy: make deploy"
if [ $# -eq 0 ]; then
    echo ""
    echo "To install Pepper MCP into an app repo:"
    echo "  ./setup.sh ~/Developer/your-app"
fi
echo ""

#!/bin/bash
# scripts/setup-ci-agents.sh — install GitHub Actions agent workflows
#
# Copies workflow templates from scripts/workflows/ into .github/workflows/
# and validates the ANTHROPIC_API_KEY secret is configured.
#
# Usage: ./scripts/setup-ci-agents.sh [--check]
#   --check   Dry-run: show what would be installed, verify secret exists

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

SRC_DIR="scripts/workflows"
DST_DIR=".github/workflows"
CHECK_ONLY=false

if [ "${1:-}" = "--check" ]; then
  CHECK_ONLY=true
fi

# Verify source templates exist
TEMPLATES=$(ls "$SRC_DIR"/agent-*.yml 2>/dev/null || true)
if [ -z "$TEMPLATES" ]; then
  echo "Error: no workflow templates found in $SRC_DIR/"
  exit 1
fi

echo "Pepper CI Agent Setup"
echo "====================="
echo ""

# Check gh auth
if ! gh auth status &>/dev/null; then
  echo "Error: gh not authenticated. Run: gh auth login"
  exit 1
fi

# Check for ANTHROPIC_API_KEY secret
REPO="skwallace36/Pepper"
HAS_SECRET=false
if gh secret list --repo "$REPO" 2>/dev/null | grep -q "ANTHROPIC_API_KEY"; then
  HAS_SECRET=true
  echo "[ok] ANTHROPIC_API_KEY secret is configured"
else
  echo "[!!] ANTHROPIC_API_KEY secret NOT found"
  echo "     Set it: gh secret set ANTHROPIC_API_KEY --repo $REPO"
fi
echo ""

# List workflows to install
echo "Workflows to install:"
for tmpl in $TEMPLATES; do
  name=$(basename "$tmpl")
  # Extract the workflow name from the YAML
  display=$(grep '^name:' "$tmpl" | head -1 | sed 's/^name: //')
  trigger=$(grep '^  ' "$tmpl" | head -1 | sed 's/^  //' | tr -d ':')
  if [ -f "$DST_DIR/$name" ]; then
    status="[update]"
  else
    status="[new]   "
  fi
  echo "  $status $name — $display"
done
echo ""

# Agent classification
echo "Agent classification:"
echo "  CI (Linux runners, no simulator):"
echo "    - pr-responder  → triggers on PR reviews and @claude comments"
echo "    - bugfix        → triggers on issues labeled 'bug'"
echo "    - builder       → triggers on schedule (2x/day) or manual dispatch"
echo "    - researcher    → triggers on issues labeled 'research'"
echo ""
echo "  Local only (requires simulator):"
echo "    - tester        → stays on local heartbeat (needs simulator)"
echo "    - pr-verifier   → stays on local heartbeat (needs build + deploy)"
echo ""

if [ "$CHECK_ONLY" = true ]; then
  echo "Dry run — no files changed."
  if [ "$HAS_SECRET" = false ]; then
    echo ""
    echo "Action required: set the ANTHROPIC_API_KEY secret before workflows can run."
  fi
  exit 0
fi

# Install workflows (replace placeholder with actual GitHub Actions secret ref)
SECRET_REF='${{ secrets.ANTHROPIC_API_KEY }}'
mkdir -p "$DST_DIR"
INSTALLED=0
for tmpl in $TEMPLATES; do
  name=$(basename "$tmpl")
  sed "s|__ANTHROPIC_SECRET_REF__|${SECRET_REF}|g" "$tmpl" > "$DST_DIR/$name"
  INSTALLED=$((INSTALLED + 1))
done

echo "Installed $INSTALLED workflow(s) to $DST_DIR/"
echo ""

if [ "$HAS_SECRET" = false ]; then
  echo "IMPORTANT: Set the ANTHROPIC_API_KEY secret before workflows can run:"
  echo "  gh secret set ANTHROPIC_API_KEY --repo $REPO"
  echo ""
fi

echo "Next steps:"
echo "  1. Review the installed workflows in $DST_DIR/"
echo "  2. Commit and push to enable them"
echo "  3. Local heartbeat continues for tester + pr-verifier"
echo ""
echo "To disable CI agents: remove the workflow files and push."
echo "To stop all agents: make agents-stop (or ./scripts/agent-kill.sh)"

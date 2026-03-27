#!/bin/bash
set -euo pipefail

# scripts/pr-transition.sh — atomic PR label state machine transitions
#
# Usage:
#   pr-transition.sh <pr-number> <new-state>
#
# States: awaiting:verifier, awaiting:responder, awaiting:human, verified
#
# Removes ALL state labels first, then adds the new one. Single source of
# truth for the PR state machine — agents call this instead of raw gh commands.

REPO="skwallace36/Pepper-private"
PR="${1:?Usage: pr-transition.sh <pr-number> <new-state>}"
NEW_STATE="${2:?Usage: pr-transition.sh <pr-number> <new-state>}"

# All valid state labels
STATES="awaiting:verifier awaiting:responder awaiting:human verified"

# Validate new state
VALID=false
for s in $STATES; do
  [ "$s" = "$NEW_STATE" ] && VALID=true
done
if [ "$VALID" = false ]; then
  echo "Error: invalid state '$NEW_STATE'. Valid: $STATES" >&2
  exit 1
fi

# Remove all state labels first (ignore errors for labels that aren't set)
for label in $STATES; do
  gh pr edit "$PR" --repo "$REPO" --remove-label "$label" 2>/dev/null || true
done

# Add the new state label
gh pr edit "$PR" --repo "$REPO" --add-label "$NEW_STATE"

echo "PR #$PR → $NEW_STATE"

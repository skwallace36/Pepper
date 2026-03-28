#!/bin/bash
set -euo pipefail

# scripts/pr-transition.sh — atomic PR label state machine transitions
#
# Usage:
#   pr-transition.sh <pr-number> <new-state> [comment]
#
# States: awaiting:verifier, awaiting:responder, awaiting:human, verified
#
# Removes ALL state labels first, then adds the new one. Single source of
# truth for the PR state machine — agents call this instead of raw gh commands.
#
# When transitioning to awaiting:responder, a comment is REQUIRED (the script
# will exit 1 without it). The comment is posted to the PR automatically.

REPO="skwallace36/Pepper-private"
PR="${1:?Usage: pr-transition.sh <pr-number> <new-state> [comment]}"
NEW_STATE="${2:?Usage: pr-transition.sh <pr-number> <new-state> [comment]}"
COMMENT="${3:-}"

# Require a comment when rejecting to awaiting:responder — without this,
# the responder agent has nothing to act on (see issue #745).
if [ "$NEW_STATE" = "awaiting:responder" ] && [ -z "$COMMENT" ]; then
  echo "Error: comment is required when transitioning to awaiting:responder." >&2
  echo "Usage: pr-transition.sh <pr-number> awaiting:responder \"<what failed>\"" >&2
  echo "If you can't articulate specific failures, use awaiting:human instead." >&2
  exit 1
fi

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

# Post the comment to the PR if one was provided
if [ -n "$COMMENT" ]; then
  gh pr comment "$PR" --repo "$REPO" --body "$COMMENT"
fi

echo "PR #$PR → $NEW_STATE"

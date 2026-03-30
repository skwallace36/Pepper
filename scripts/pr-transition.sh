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

# Sim proof requirement: PRs touching dylib/test-app Swift/ObjC files
# must have verifier proof (look output, crash_log, screenshots) in PR
# comments before transitioning to verified or awaiting:human.
if [ "$NEW_STATE" = "verified" ] || [ "$NEW_STATE" = "awaiting:human" ]; then
  # Check if PR has dylib/test-app changes
  NEEDS_SIM=$(gh pr diff "$PR" --repo "$REPO" --name-only 2>/dev/null | \
    grep -cE '^(dylib/|test-app/).*\.(swift|m|mm|c|h)$' || echo 0)

  if [ "$NEEDS_SIM" -gt 0 ]; then
    # Check PR comments for proof of sim testing
    HAS_PROOF=$(gh api "repos/$REPO/issues/$PR/comments" \
      --jq '[.[] | .body] | join("\n")' 2>/dev/null | \
      grep -ciE 'Screen:|interactive.*elements|SYSTEM DIALOG|crash_log|no crash|app is running|deployed|look.*output|screenshot|\.jpg|\.png|pepper-agent/pr-verifier' || echo 0)

    if [ "$HAS_PROOF" -eq 0 ]; then
      echo "Error: PR #$PR touches dylib/test-app files but has no sim test proof." >&2
      echo "The verifier must deploy, crash-check, and post look/crash_log output before transitioning." >&2
      echo "Post proof as a PR comment first, then retry this transition." >&2
      exit 1
    fi
  fi
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

#!/bin/bash
# scripts/classify-pr.sh — set the initial awaiting: label on a new PR
#
# Usage: classify-pr.sh <pr-number>
#
# New PRs get `awaiting:verifier`. The verifier determines HOW to verify
# (code review vs sim test) from the diff itself.
#
# State machine:
#   builder opens PR     → awaiting:verifier
#   verifier verifies    → verified (auto-merge) or awaiting:human (needs approval)
#   human comments       → awaiting:responder
#   responder addresses  → awaiting:verifier
#   human says LGTM      → verified (merge)

set -euo pipefail

REPO="skwallace36/Pepper"
PR="${1:?Usage: classify-pr.sh <pr-number>}"

# Remove any existing state labels, then set the right one
for label in awaiting:verifier awaiting:responder awaiting:human verified; do
  gh pr edit "$PR" --repo "$REPO" --remove-label "$label" 2>/dev/null || true
done

gh pr edit "$PR" --repo "$REPO" --add-label "awaiting:verifier" 2>/dev/null || true

#!/bin/bash
# scripts/pr-digest.sh — generate a prioritized PR review digest
#
# Groups open PRs by risk level and verification status so the human
# reviewer can batch-review efficiently instead of triaging one at a time.
#
# Usage: ./scripts/pr-digest.sh [--json]
#
# Exit codes: 0 = PRs to review, 1 = error, 2 = no open PRs

set -euo pipefail

REPO="skwallace36/Pepper-private"
JSON_MODE=false
[ "${1:-}" = "--json" ] && JSON_MODE=true

# Files that require human review (mirrors pr-verifier.md gate list)
SENSITIVE_PATTERNS='Makefile|\.claude/|\.github/|scripts/agent-|scripts/hooks/|scripts/prompts/|tools/pepper-mcp|\.env'

# Fetch all open PRs with metadata
PRS=$(gh pr list --repo "$REPO" --state open --json number,title,headRefName,labels,author,additions,deletions,changedFiles,createdAt,reviewDecision 2>/dev/null)

if [ -z "$PRS" ] || [ "$PRS" = "[]" ]; then
  echo "No open PRs."
  exit 2
fi

PR_COUNT=$(echo "$PRS" | jq 'length')

# Classify each PR
classify_pr() {
  local number="$1"

  # Check labels
  local labels
  labels=$(echo "$PRS" | jq -r ".[] | select(.number == $number) | .labels | map(.name) | join(\",\")")
  local is_verified=false
  echo "$labels" | grep -q "verified" && is_verified=true

  # Get diff stat to check for sensitive files
  local files_changed
  files_changed=$(gh pr diff "$number" --repo "$REPO" --name-only 2>/dev/null || echo "")

  local touches_sensitive=false
  if echo "$files_changed" | grep -qE "$SENSITIVE_PATTERNS"; then
    touches_sensitive=true
  fi

  # Get line counts
  local additions deletions
  additions=$(echo "$PRS" | jq -r ".[] | select(.number == $number) | .additions")
  deletions=$(echo "$PRS" | jq -r ".[] | select(.number == $number) | .deletions")
  local total_lines=$(( additions + deletions ))

  # Classify risk
  if [ "$touches_sensitive" = true ]; then
    echo "infrastructure"
  elif [ "$total_lines" -le 50 ]; then
    echo "low-risk"
  elif [ "$total_lines" -le 200 ]; then
    echo "moderate"
  else
    echo "large"
  fi
}

# Collect PR data with classification
declare -a INFRA_PRS=()
declare -a LOW_PRS=()
declare -a MOD_PRS=()
declare -a LARGE_PRS=()
declare -a VERIFIED_READY=()

for number in $(echo "$PRS" | jq -r '.[].number'); do
  title=$(echo "$PRS" | jq -r ".[] | select(.number == $number) | .title")
  additions=$(echo "$PRS" | jq -r ".[] | select(.number == $number) | .additions")
  deletions=$(echo "$PRS" | jq -r ".[] | select(.number == $number) | .deletions")
  labels=$(echo "$PRS" | jq -r ".[] | select(.number == $number) | .labels | map(.name) | join(\", \")")
  created=$(echo "$PRS" | jq -r ".[] | select(.number == $number) | .createdAt" | cut -dT -f1)

  is_verified=false
  echo "$labels" | grep -q "verified" && is_verified=true

  risk=$(classify_pr "$number")

  entry="  #${number} ${title} (+${additions}/-${deletions}, ${created})"
  if [ -n "$labels" ]; then
    entry="$entry [$labels]"
  fi

  if [ "$is_verified" = true ] && [ "$risk" != "infrastructure" ]; then
    VERIFIED_READY+=("$entry")
  else
    case "$risk" in
      infrastructure) INFRA_PRS+=("$entry") ;;
      low-risk)       LOW_PRS+=("$entry") ;;
      moderate)       MOD_PRS+=("$entry") ;;
      large)          LARGE_PRS+=("$entry") ;;
    esac
  fi
done

if [ "$JSON_MODE" = true ]; then
  # JSON output for programmatic consumption
  echo "$PRS" | jq --arg sp "$SENSITIVE_PATTERNS" '
    [.[] | {
      number,
      title,
      additions,
      deletions,
      labels: [.labels[].name],
      created: .createdAt,
      verified: ([.labels[].name] | index("verified") != null)
    }]'
  exit 0
fi

# Human-readable digest
echo "═══════════════════════════════════════════════════"
echo "  PR Review Digest — $(date +%Y-%m-%d) — $PR_COUNT open"
echo "═══════════════════════════════════════════════════"
echo ""

if [ ${#VERIFIED_READY[@]} -gt 0 ]; then
  echo "✓ VERIFIED & READY TO MERGE (${#VERIFIED_READY[@]})"
  echo "  These passed pr-verifier. Quick merge or skim."
  for pr in "${VERIFIED_READY[@]}"; do echo "$pr"; done
  echo ""
fi

if [ ${#LOW_PRS[@]} -gt 0 ]; then
  echo "◎ LOW RISK — unverified (${#LOW_PRS[@]})"
  echo "  Small diffs (≤50 lines), no sensitive files."
  for pr in "${LOW_PRS[@]}"; do echo "$pr"; done
  echo ""
fi

if [ ${#MOD_PRS[@]} -gt 0 ]; then
  echo "△ MODERATE (${#MOD_PRS[@]})"
  echo "  Medium diffs (51-200 lines), worth a closer look."
  for pr in "${MOD_PRS[@]}"; do echo "$pr"; done
  echo ""
fi

if [ ${#LARGE_PRS[@]} -gt 0 ]; then
  echo "▲ LARGE (${#LARGE_PRS[@]})"
  echo "  200+ lines changed. Set aside time for these."
  for pr in "${LARGE_PRS[@]}"; do echo "$pr"; done
  echo ""
fi

if [ ${#INFRA_PRS[@]} -gt 0 ]; then
  echo "⚠ INFRASTRUCTURE (${#INFRA_PRS[@]})"
  echo "  Touches Makefile, agent scripts, prompts, or config."
  echo "  Cannot be auto-merged — requires human judgment."
  for pr in "${INFRA_PRS[@]}"; do echo "$pr"; done
  echo ""
fi

# Summary line
TOTAL_READY=${#VERIFIED_READY[@]}
TOTAL_QUICK=$(( ${#VERIFIED_READY[@]} + ${#LOW_PRS[@]} ))
echo "───────────────────────────────────────────────────"
echo "  Quick wins: $TOTAL_QUICK  |  Needs review: $(( ${#MOD_PRS[@]} + ${#LARGE_PRS[@]} + ${#INFRA_PRS[@]} ))  |  Total: $PR_COUNT"
echo "═══════════════════════════════════════════════════"

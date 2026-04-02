#!/bin/bash
# scripts/hooks/pre-push-rebase.sh
# Git pre-push hook: auto-rebase ALL branches against origin/main before pushing.
# Blocks direct pushes to main. Rebases everything else.
# Install: ln -sf ../../scripts/hooks/pre-push-rebase.sh .git/hooks/pre-push

BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)

# Allow tag-only pushes from main (releases).
# Pre-push stdin format: <local ref> <local sha> <remote ref> <remote sha>
TAG_ONLY=true
while read -r LOCAL_REF _ REMOTE_REF _; do
  case "$REMOTE_REF" in
    refs/tags/*) ;;  # tag push — allowed
    *) TAG_ONLY=false ;;
  esac
done

# Protect main: block branch pushes. Tag pushes go through (for releases).
if [ "$TAG_ONLY" = false ] && { [ "$BRANCH" = "main" ] || [ "$BRANCH" = "master" ]; }; then
  echo ""
  echo "╔══════════════════════════════════════════════════════════╗"
  echo "║  BLOCKED: Direct push to $BRANCH is not allowed.       ║"
  echo "╠══════════════════════════════════════════════════════════╣"
  echo "║                                                         ║"
  echo "║  Create a branch and open a PR instead:                 ║"
  echo "║                                                         ║"
  echo "║    git checkout -b my-branch                            ║"
  echo "║    git push -u origin my-branch                         ║"
  echo "║    gh pr create --title \"...\" --body \"...\"              ║"
  echo "║    gh pr merge --squash --delete-branch                 ║"
  echo "║                                                         ║"
  echo "║  If you already committed to main by accident:          ║"
  echo "║                                                         ║"
  echo "║    git checkout -b my-branch                            ║"
  echo "║    git push -u origin my-branch                         ║"
  echo "║    git checkout main                                    ║"
  echo "║    git reset --hard origin/main                         ║"
  echo "║                                                         ║"
  echo "╚══════════════════════════════════════════════════════════╝"
  echo ""
  exit 1
fi

# Rebase ALL non-main branches — agents and interactive sessions alike

# Fetch latest main
git fetch origin main --quiet 2>/dev/null || exit 0

# Check if we're behind main
BEHIND=$(git rev-list --count HEAD..origin/main 2>/dev/null || echo 0)
if [ "$BEHIND" -gt 0 ]; then
  echo "Auto-rebasing $BRANCH against origin/main ($BEHIND commits behind)..."
  if git rebase origin/main --quiet 2>/dev/null; then
    echo "Rebase succeeded."
  else
    echo "Rebase failed (conflicts). Aborting rebase and push."
    git rebase --abort 2>/dev/null
    exit 1
  fi
fi

exit 0

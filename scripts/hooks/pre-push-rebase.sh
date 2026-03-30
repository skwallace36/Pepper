#!/bin/bash
# scripts/hooks/pre-push-rebase.sh
# Git pre-push hook: auto-rebase agent branches against origin/main before pushing.
# Only active for agent/* branches. Interactive branches are unaffected.
# Install: ln -sf ../../scripts/hooks/pre-push-rebase.sh .git/hooks/pre-push

BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)

# Protect main: block ALL direct pushes. Everything goes through PRs.
if [ "$BRANCH" = "main" ] || [ "$BRANCH" = "master" ]; then
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

# Only rebase agent branches
case "$BRANCH" in
  agent/*) ;;
  *) exit 0 ;;  # Non-agent branch, skip
esac

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

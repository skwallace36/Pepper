#!/bin/bash
# scripts/hooks/post-merge-trigger.sh
# Git post-merge hook: trigger agents based on what changed.
# Runs after every `git pull` that merges new commits.
# Install: ln -sf ../../scripts/hooks/post-merge-trigger.sh .git/hooks/post-merge

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

# What files changed in the merge?
CHANGED=$(git diff-tree -r --name-only --no-commit-id HEAD@{1} HEAD 2>/dev/null || true)
[ -z "$CHANGED" ] && exit 0

# Trigger based on changed files (background, don't block the merge)
if echo "$CHANGED" | grep -q "dylib/\|tools/"; then
  # Code changes merged — run tester to check for regressions
  nohup ./scripts/agent-trigger.sh push-to-main >> build/logs/trigger.log 2>&1 &
fi

exit 0

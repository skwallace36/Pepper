#!/bin/bash
# post-checkout hook — prevent agents from leaving primary worktree on wrong branch.
#
# If a pepper-agent process checks out a non-main branch on the primary worktree,
# immediately switch back to main. Agents should ONLY work in .claude/worktrees/.
#
# This doesn't block the checkout (git has no pre-checkout hook), but it auto-corrects.

PREV_HEAD="$1"
NEW_HEAD="$2"
BRANCH_FLAG="$3"  # 1 = branch checkout, 0 = file checkout

# Only act on branch checkouts
[ "$BRANCH_FLAG" != "1" ] && exit 0

# Only act if we're in the primary worktree (not a .claude/worktree)
WORKTREE_DIR=$(git rev-parse --show-toplevel 2>/dev/null)
if echo "$WORKTREE_DIR" | grep -q "\.claude/worktrees/"; then
  exit 0  # This IS a worktree, fine
fi

# Check current branch
BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)

# If an agent process checked out a non-main branch on the primary worktree, fix it
if [ "$BRANCH" != "main" ] && [ -n "$PEPPER_AGENT_TYPE" ]; then
  echo "WARNING: agent $PEPPER_AGENT_TYPE checked out '$BRANCH' on primary worktree. Switching back to main."
  git checkout main --quiet 2>/dev/null || true
fi

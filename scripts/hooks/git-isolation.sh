#!/bin/bash
# scripts/hooks/git-isolation.sh — enforce git isolation for ALL Claude sessions
#
# Called as a PreToolUse hook on Bash commands. Enforces:
#   1. No commits on main — must create a branch first
#   2. No pushes to main — must go through PR
#   3. No stashing in agent sessions — agents use worktrees
#   4. Pushes must be rebased on latest origin/main
#   5. Branches must be based on up-to-date main
#
# Reads JSON from stdin: {"tool_input":{"command":"..."}}

set -euo pipefail

input=$(cat)
cmd=$(echo "$input" | jq -r '.tool_input.command // empty')
[ -z "$cmd" ] && exit 0

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo "")"
[ -z "$REPO_ROOT" ] && exit 0

branch=$(git -C "$REPO_ROOT" branch --show-current 2>/dev/null || echo "")

# ── 1. Block commits on main ──────────────────────────────────────────
# Match git commit anywhere in a command chain (&&, ||, ;, |, subshell)
if echo "$cmd" | grep -qE '(^|[;&|]\s*)git\s+commit'; then
  if [ "$branch" = "main" ]; then
    cat >&2 <<'MSG'
Blocked: cannot commit directly to main.

  git checkout -b my-branch   # create a branch first
  git commit ...              # then commit
MSG
    exit 2
  fi
fi

# ── 2. Block direct pushes to main ───────────────────────────────────
if echo "$cmd" | grep -qE '(^|[;&|]\s*)git\s+push'; then
  # Block if currently on main (pushing current branch = pushing main)
  if [ "$branch" = "main" ]; then
    cat >&2 <<'MSG'
Blocked: cannot push main directly. Use a branch + PR:

  git checkout -b my-branch
  git push -u origin my-branch
  gh pr create --title "..." --body "..."
  gh pr merge --squash --delete-branch
MSG
    exit 2
  fi

  # Block explicit push to main/master ref
  if echo "$cmd" | grep -qE 'git\s+push\s+\S+\s+(main|master)'; then
    echo "Blocked: cannot push to main/master. Use a PR." >&2
    exit 2
  fi

  # ── 4. Enforce rebase before push ────────────────────────────────
  # Fetch latest main and check if branch needs rebase
  git -C "$REPO_ROOT" fetch origin main --quiet 2>/dev/null || true
  BEHIND=$(git -C "$REPO_ROOT" rev-list --count HEAD..origin/main 2>/dev/null || echo 0)
  if [ "$BEHIND" -gt 0 ]; then
    cat >&2 <<MSG
Blocked: branch '$branch' is $BEHIND commit(s) behind origin/main. Rebase first:

  git fetch origin main
  git rebase origin/main
  # then retry push
MSG
    exit 2
  fi
fi

# ── 3. Block stash in agent sessions ─────────────────────────────────
if [ -n "${PEPPER_AGENT_TYPE:-}" ]; then
  if echo "$cmd" | grep -qE '(^|[;&|]\s*)git\s+stash'; then
    echo "Blocked: agents must not use git stash. You're in an isolated worktree — commit or discard instead." >&2
    exit 2
  fi
fi

# ── 5. Ensure new branches start from up-to-date main ────────────────
if echo "$cmd" | grep -qE '(^|[;&|]\s*)git\s+(checkout\s+-b|switch\s+-c)'; then
  if [ "$branch" = "main" ]; then
    git -C "$REPO_ROOT" fetch origin main --quiet 2>/dev/null || true
    LOCAL=$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || echo "")
    REMOTE=$(git -C "$REPO_ROOT" rev-parse origin/main 2>/dev/null || echo "")
    if [ -n "$LOCAL" ] && [ -n "$REMOTE" ] && [ "$LOCAL" != "$REMOTE" ]; then
      BEHIND=$(git -C "$REPO_ROOT" rev-list --count HEAD..origin/main 2>/dev/null || echo 0)
      cat >&2 <<MSG
Blocked: local main is $BEHIND commit(s) behind origin/main. Update first:

  git pull origin main
  git checkout -b my-branch   # then create branch
MSG
      exit 2
    fi
  fi
fi

exit 0

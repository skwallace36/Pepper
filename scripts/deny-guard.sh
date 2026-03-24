#!/bin/bash
# Deny guard — logs denied tool calls for rule tuning.
# Called as a PreToolUse hook on Bash commands.
# Logs to build/logs/deny.log in the main repo (not worktrees).

input=$(cat)
cmd=$(echo "$input" | jq -r '.tool_input.command // empty')
[ -z "$cmd" ] && exit 0

# Patterns mirroring the deny list in .claude/settings.json
DENY_RE='(sudo |rm -rf [/~.]|git push.*(--force|-f )|git reset --hard|git clean -f|git branch -D |killall |pkill |chmod.777|chown |launchctl |defaults write |networksetup |diskutil |brew (uninstall|remove)|pip3? install|npm install -g|npx -y)'

if echo "$cmd" | grep -qE "$DENY_RE"; then
  # Resolve main repo root (not worktree)
  MAIN_REPO=$(git worktree list --porcelain 2>/dev/null | head -1 | sed 's/^worktree //')
  [ -z "$MAIN_REPO" ] && MAIN_REPO=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
  LOG="$MAIN_REPO/build/logs/deny.log"
  mkdir -p "$(dirname "$LOG")"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) cmd=$cmd" >> "$LOG"
fi

# Belt-and-suspenders: block push to main even if deny patterns miss a variant
if echo "$cmd" | grep -qE 'git push' && echo "$cmd" | grep -qE '\b(main|master)\b'; then
  echo "DENY: push to main blocked — use a branch + PR"
fi

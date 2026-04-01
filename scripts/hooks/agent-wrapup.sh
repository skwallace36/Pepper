#!/bin/bash
# scripts/hooks/agent-wrapup.sh
# PostToolUse hook: inject wrap-up reminder when runner signals time is running out.
# The runner creates PEPPER_WRAPUP_FILE at 80% of the timeout.
# This hook checks for that file and injects a deterministic reminder.
# No-op for interactive sessions (PEPPER_WRAPUP_FILE unset).

WRAPUP_FILE="${PEPPER_WRAPUP_FILE:-}"
[ -z "$WRAPUP_FILE" ] && exit 0
[ -f "$WRAPUP_FILE" ] || exit 0

# Consume stdin (required by hook protocol)
cat > /dev/null

# File exists — inject wrap-up reminder. Only fires once per tool call
# after the signal, so the agent sees it repeatedly until it wraps up.
cat <<'MSG'
⏰ TIME CHECK: You are running low on time. You MUST wrap up NOW:

1. STOP investigating. Do NOT start new file reads or searches.
2. If you have a fix ready: commit, push, open PR.
3. If you do NOT have a fix ready: comment on the issue with:
   - What you investigated (files, functions, patterns checked)
   - What you found (root cause hypothesis, relevant code paths)
   - What remains to be done (specific next steps for the next agent run)
4. This is your LAST CHANCE to preserve your work before timeout.
MSG

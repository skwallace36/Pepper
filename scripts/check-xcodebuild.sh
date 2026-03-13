#!/bin/bash
# Claude Code PreToolUse hook — blocks raw xcodebuild, forces wrapper usage.
#
# Install: Add to .claude/settings.local.json hooks:
#   "PreToolUse": [{ "matcher": "Bash", "command": "/path/to/pepper/scripts/check-xcodebuild.sh" }]
#
# Denies any Bash command containing "xcodebuild" unless it routes through
# the pepper wrapper script (scripts/xcodebuild.sh).

input=$(cat)
command=$(echo "$input" | jq -r '.tool_input.command // empty')

# Find the pepper scripts dir (same dir as this script)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WRAPPER="$SCRIPT_DIR/xcodebuild.sh"

if echo "$command" | grep -q "xcodebuild" && ! echo "$command" | grep -q "scripts/xcodebuild.sh" && ! echo "$command" | grep -qE -- "-scheme (GenerateAPI|DownloadSchema)"; then
  cat << EOF
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": "Raw xcodebuild is blocked — worktree isolation requires the wrapper.\n\nUse Pepper MCP tools instead:\n  - Simulator: mcp__pepper__build or mcp__pepper__iterate\n  - Device: mcp__pepper__build_device\n\nOr the wrapper directly: $WRAPPER"
  }
}
EOF
  exit 0
fi

exit 0

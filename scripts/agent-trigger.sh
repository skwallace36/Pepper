#!/bin/bash
# scripts/agent-trigger.sh — launch an agent based on a specific event
# Called by webhook receiver or git hooks with an event type argument.
#
# Usage:
#   ./scripts/agent-trigger.sh bug-filed        # new bug → bugfix
#   ./scripts/agent-trigger.sh pr-opened        # new PR → pr-verifier
#   ./scripts/agent-trigger.sh pr-reviewed      # review comment → pr-responder
#   ./scripts/agent-trigger.sh push-to-main     # code merged → tester (if coverage gaps)

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

EVENT="${1:?Usage: agent-trigger.sh <event-type>}"

[ -f .pepper-kill ] && exit 0

# Don't stack — if same agent type is running, skip
agent_running() {
  local lock="build/logs/.lock-$1"
  [ -f "$lock" ] && kill -0 "$(cat "$lock" 2>/dev/null)" 2>/dev/null
}

case "$EVENT" in
  bug-filed|bug)
    agent_running bugfix && exit 0
    echo "$(date +%H:%M) TRIGGER[$EVENT] → bugfix"
    exec ./scripts/agent-runner.sh bugfix
    ;;
  pr-opened|pr)
    agent_running pr-verifier && exit 0
    echo "$(date +%H:%M) TRIGGER[$EVENT] → pr-verifier"
    exec ./scripts/agent-runner.sh pr-verifier
    ;;
  pr-reviewed|review)
    agent_running pr-responder && exit 0
    echo "$(date +%H:%M) TRIGGER[$EVENT] → pr-responder"
    exec ./scripts/agent-runner.sh pr-responder
    ;;
  push-to-main|push|merged)
    agent_running tester && exit 0
    echo "$(date +%H:%M) TRIGGER[$EVENT] → tester"
    exec ./scripts/agent-runner.sh tester
    ;;
  *)
    echo "Unknown event: $EVENT"
    echo "Events: bug-filed, pr-opened, pr-reviewed, push-to-main"
    exit 1
    ;;
esac

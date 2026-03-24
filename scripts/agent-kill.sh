#!/bin/bash
# scripts/agent-kill.sh — kill all agents, runners, and heartbeat immediately.

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

# Kill heartbeat
if [ -f build/logs/heartbeat.pid ]; then
  HB_PID=$(cat build/logs/heartbeat.pid 2>/dev/null)
  if [ -n "$HB_PID" ] && kill -0 "$HB_PID" 2>/dev/null; then
    kill -TERM "$HB_PID" 2>/dev/null || true
  fi
  rm -f build/logs/heartbeat.pid
fi

# Kill all agent claude processes
while IFS= read -r pid; do
  kill -TERM "$pid" 2>/dev/null || true
done < <(pgrep -f 'append-system-prompt' 2>/dev/null)

# Kill all agent-runner processes
while IFS= read -r pid; do
  kill -TERM "$pid" 2>/dev/null || true
done < <(pgrep -f 'agent-runner\.sh' 2>/dev/null)

# Clean lock files
rm -f build/logs/.lock-* 2>/dev/null || true

# Force-kill survivors
sleep 1
while IFS= read -r pid; do
  kill -9 "$pid" 2>/dev/null || true
done < <(pgrep -f 'append-system-prompt' 2>/dev/null)

echo "All agents killed."

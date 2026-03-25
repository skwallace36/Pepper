#!/bin/bash
# scripts/agent-kill.sh — kill all agents, runners, and heartbeat immediately.
#
# The heartbeat runs as a process group leader. All runners and agent processes
# inherit that group. Killing the group takes everything down in one shot.

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

KILLED=false

# Primary path: kill the heartbeat's process group (takes all children with it)
if [ -f build/logs/heartbeat.pid ]; then
  HB_PID=$(cat build/logs/heartbeat.pid 2>/dev/null)
  if [ -n "$HB_PID" ] && kill -0 "$HB_PID" 2>/dev/null; then
    # Kill the entire process group
    kill -TERM -"$HB_PID" 2>/dev/null || true
    sleep 1
    kill -9 -"$HB_PID" 2>/dev/null || true
    KILLED=true
  fi
  rm -f build/logs/heartbeat.pid
fi

# Fallback: sweep for orphans (shouldn't exist, but be thorough)
for pattern in 'pepper-agent-' 'agent-runner\.sh' 'agent-heartbeat\.sh'; do
  while IFS= read -r pid; do
    kill -TERM "$pid" 2>/dev/null || true
  done < <(pgrep -f "$pattern" 2>/dev/null)
done
sleep 1
for pattern in 'pepper-agent-' 'agent-runner\.sh' 'agent-heartbeat\.sh'; do
  while IFS= read -r pid; do
    kill -9 "$pid" 2>/dev/null || true
  done < <(pgrep -f "$pattern" 2>/dev/null)
done

# Clean lock files
rm -f build/logs/.lock-* 2>/dev/null || true

echo "All agents killed."

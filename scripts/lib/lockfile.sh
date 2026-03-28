#!/bin/bash
# scripts/lib/lockfile.sh — lockfile helpers with PID-reuse protection
#
# Lockfiles store PID on line 1 and process start time on line 2.
# Liveness checks verify both PID existence AND matching start time,
# preventing false positives when the OS reuses a dead agent's PID.
#
# Source this file; do not execute directly.

# Write a lockfile for the current process.
# Usage: lockfile_write <path>
lockfile_write() {
  local lf="$1"
  printf '%s\n' $$ > "$lf"
  ps -o lstart= -p $$ 2>/dev/null | sed 's/^ *//' >> "$lf"
}

# Read PID from lockfile (line 1). Prints empty string on failure.
# Usage: lockfile_pid <path>
lockfile_pid() {
  sed -n '1p' "$1" 2>/dev/null
}

# Check if lockfile's process is still the original agent.
# Returns 0 if alive and start time matches, 1 if stale/dead.
# Usage: lockfile_alive <path>
lockfile_alive() {
  local lf="$1"
  [ -f "$lf" ] || return 1
  local lpid lstart
  lpid=$(sed -n '1p' "$lf" 2>/dev/null)
  lstart=$(sed -n '2p' "$lf" 2>/dev/null)
  [ -n "$lpid" ] || return 1
  kill -0 "$lpid" 2>/dev/null || return 1
  # If start time was recorded, verify it still matches (detects PID reuse)
  if [ -n "$lstart" ]; then
    local current
    current=$(ps -o lstart= -p "$lpid" 2>/dev/null | sed 's/^ *//')
    [ "$current" = "$lstart" ] || return 1
  fi
  return 0
}

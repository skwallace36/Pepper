#!/bin/bash
# scripts/hooks/agent-drift-detector.sh
# Drift/loop detection for autonomous agents.
# Warns agents when stuck in read-only loops or consecutive errors,
# then escalates to blocking if the pattern continues after warning.
#
# Modes:
#   reset                                             Clear state (called by runner on startup)
#   track <tool> [--file PATH] [--error] [--write]   Update state (called by PostToolUse)
#   check                                             Check thresholds (called by PreToolUse)
#
# Requires: PEPPER_AGENT_TYPE, PEPPER_EVENTS_LOG

set -euo pipefail

AGENT="${PEPPER_AGENT_TYPE:-}"
[ -z "$AGENT" ] && exit 0

EVENTS_LOG="${PEPPER_EVENTS_LOG:-}"
[ -z "$EVENTS_LOG" ] && exit 0

LOG_DIR=$(dirname "$EVENTS_LOG")
STATE_DIR="$LOG_DIR/drift-$AGENT"

# --- Thresholds ---
# Unified for all types — complex tasks (bugfix, builder, researcher) all
# need room to explore. The reread ratio catches actual loops better than
# a low read-streak cap.
READ_WARN=25          # consecutive read-only ops → warning
READ_KILL=50          # consecutive read-only ops → block (after warning)
REREAD_WARN=12        # re-reads of same files → warning
ERROR_WARN=5          # consecutive errors → warning
ERROR_KILL=10         # consecutive errors → block (after warning)

MODE="${1:-check}"
shift || true

# --- Helpers ---

read_counter() {
  local file="$STATE_DIR/$1"
  if [ -f "$file" ]; then cat "$file"; else echo "0"; fi
}

write_counter() {
  local file="$STATE_DIR/$1"
  local val="$2"
  printf '%s' "$val" > "$file.tmp" && mv "$file.tmp" "$file"
}

increment_counter() {
  local current
  current=$(read_counter "$1")
  write_counter "$1" "$(( current + 1 ))"
}

emit_drift_event() {
  local event="$1" detail="$2"
  echo "{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"agent\":\"${AGENT}\",\"event\":\"drift-${event}\",\"detail\":$(printf '%s' "$detail" | jq -Rs '.')}" >> "$EVENTS_LOG"
}

# --- RESET mode (called by agent-runner on startup) ---

if [ "$MODE" = "reset" ]; then
  rm -rf "$STATE_DIR"
  mkdir -p "$STATE_DIR"
  touch "$STATE_DIR/reads.log"
  exit 0
fi

mkdir -p "$STATE_DIR"

# --- TRACK mode (PostToolUse) ---

if [ "$MODE" = "track" ]; then
  TOOL="${1:-}"
  shift || true

  FILE=""
  IS_ERROR=false
  IS_WRITE=false

  while [ $# -gt 0 ]; do
    case "$1" in
      --file)  FILE="${2:-}"; shift 2 ;;
      --error) IS_ERROR=true; shift ;;
      --write) IS_WRITE=true; shift ;;
      *)       shift ;;
    esac
  done

  # --- Error tracking ---
  if [ "$IS_ERROR" = true ]; then
    increment_counter "error_streak"
    exit 0
  fi

  # Any non-error resets the error streak
  write_counter "error_streak" "0"

  # --- Write ops: reset read streak and warnings ---
  if [ "$IS_WRITE" = true ]; then
    write_counter "read_streak" "0"
    write_counter "reread_count" "0"
    rm -f "$STATE_DIR/warned_read" "$STATE_DIR/warned_error"
    : > "$STATE_DIR/reads.log"
    exit 0
  fi

  # --- Bash commands: productive work, reset read streak ---
  # Running builds, git ops, tests, etc. means the agent is actively working,
  # not stuck in a read-only loop.
  case "$TOOL" in
    Bash)
      write_counter "read_streak" "0"
      exit 0
      ;;
  esac

  # --- Read-only ops: increment streak, track re-reads ---
  case "$TOOL" in
    Read|Grep|Glob)
      increment_counter "read_streak"

      if [ "$TOOL" = "Read" ] && [ -n "$FILE" ]; then
        echo "$FILE" >> "$STATE_DIR/reads.log"
        TOTAL=$(wc -l < "$STATE_DIR/reads.log" | tr -d ' ')
        UNIQUE=$(sort -u "$STATE_DIR/reads.log" | wc -l | tr -d ' ')
        REREADS=$(( TOTAL - UNIQUE ))
        write_counter "reread_count" "$REREADS"
      fi
      ;;
  esac

  exit 0
fi

# --- CHECK mode (PreToolUse) ---

if [ "$MODE" = "check" ]; then
  READ_STREAK=$(read_counter "read_streak")
  ERROR_STREAK=$(read_counter "error_streak")
  REREAD_COUNT=$(read_counter "reread_count")

  # --- Error streak: kill ---
  if [ "$ERROR_STREAK" -ge "$ERROR_KILL" ] && [ -f "$STATE_DIR/warned_error" ]; then
    emit_drift_event "kill" "error_streak=$ERROR_STREAK"
    echo "You have hit $ERROR_STREAK consecutive errors and did not recover after warning. Stopping to prevent further drift. Comment on the issue with what you tried and exit."
    exit 2
  fi

  # --- Error streak: warn ---
  if [ "$ERROR_STREAK" -ge "$ERROR_WARN" ] && [ ! -f "$STATE_DIR/warned_error" ]; then
    touch "$STATE_DIR/warned_error"
    emit_drift_event "warn" "error_streak=$ERROR_STREAK"
    echo "WARNING: You have $ERROR_STREAK consecutive tool errors. You may be stuck in a loop. Try a different approach, or if the task is blocked, comment on the issue and exit."
    exit 0
  fi

  # --- Read-only streak: kill ---
  # Only kill if the agent is actually looping (re-reading same files).
  # High unique-file counts mean productive research, not drift.
  if [ "$READ_STREAK" -ge "$READ_KILL" ] && [ -f "$STATE_DIR/warned_read" ]; then
    # Check reread ratio — if most reads are unique files, agent is exploring
    TOTAL_READS=$(wc -l < "$STATE_DIR/reads.log" 2>/dev/null | tr -d ' ')
    UNIQUE_READS=$(sort -u "$STATE_DIR/reads.log" 2>/dev/null | wc -l | tr -d ' ')
    TOTAL_READS=${TOTAL_READS:-0}
    UNIQUE_READS=${UNIQUE_READS:-0}
    # Kill only if >40% of reads are re-reads (actually looping)
    if [ "$TOTAL_READS" -gt 0 ] && [ "$REREAD_COUNT" -gt 0 ]; then
      REREAD_PCT=$(( REREAD_COUNT * 100 / TOTAL_READS ))
      if [ "$REREAD_PCT" -lt 40 ]; then
        # Mostly unique reads — agent is exploring, not looping. Warn again but don't kill.
        emit_drift_event "warn" "read_streak=$READ_STREAK,rereads=$REREAD_COUNT,unique=$UNIQUE_READS,pct=$REREAD_PCT — exploring, not looping"
        echo "NOTE: $READ_STREAK read-only ops but only ${REREAD_PCT}% re-reads — you're exploring, not looping. Keep going but start making changes soon."
        exit 0
      fi
    fi
    emit_drift_event "kill" "read_streak=$READ_STREAK,rereads=$REREAD_COUNT"
    echo "You have done $READ_STREAK consecutive read-only operations ($REREAD_COUNT re-reads) without any writes. Stopping to prevent further drift. Comment on the issue with what you tried and exit."
    exit 2
  fi

  # --- Re-reads: warn (lower threshold for repeated reads of same files) ---
  if [ "$REREAD_COUNT" -ge "$REREAD_WARN" ] && [ ! -f "$STATE_DIR/warned_read" ]; then
    touch "$STATE_DIR/warned_read"
    emit_drift_event "warn" "rereads=$REREAD_COUNT,read_streak=$READ_STREAK"
    echo "WARNING: You have re-read the same files $REREAD_COUNT times without making changes. You may be stuck. Consider: (1) making the edit you need, (2) trying a different approach, or (3) commenting on the issue if you're blocked."
    exit 0
  fi

  # --- Read-only streak: warn ---
  if [ "$READ_STREAK" -ge "$READ_WARN" ] && [ ! -f "$STATE_DIR/warned_read" ]; then
    touch "$STATE_DIR/warned_read"
    emit_drift_event "warn" "read_streak=$READ_STREAK,rereads=$REREAD_COUNT"
    echo "WARNING: You have done $READ_STREAK consecutive read-only operations without any writes. You may be stuck researching without acting. Consider: (1) making the changes you need, (2) trying a different approach, or (3) commenting on the issue if you're blocked."
    exit 0
  fi

  exit 0
fi

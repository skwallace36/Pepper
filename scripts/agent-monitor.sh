#!/bin/bash
# scripts/agent-monitor.sh — live agent event dashboard
# Usage:
#   ./scripts/agent-monitor.sh            # live tail (new events only)
#   ./scripts/agent-monitor.sh --replay   # dump full history

EVENTS="build/logs/events.jsonl"
REPLAY=false
# Convert UTC timestamps to EST (America/New_York)
TZ_OFFSET="America/New_York"

if [ "${1:-}" = "--replay" ]; then
  REPLAY=true
  [ -n "${2:-}" ] && EVENTS="$2"
elif [ -n "${1:-}" ]; then
  EVENTS="$1"
fi

# Agent icons — visual identity per agent type
icon_for() {
  case "$1" in
    bugfix)       echo "B" ;;
    builder)      echo "W" ;;
    tester)       echo "T" ;;
    pr-responder) echo "R" ;;
    pr-verifier|verifier) echo "V" ;;
    researcher)   echo "?" ;;
    *)            echo " " ;;
  esac
}

# Color for agent name
color_for() {
  case "$1" in
    bugfix)       echo "31" ;;  # red
    builder)      echo "35" ;;  # magenta
    tester)       echo "36" ;;  # cyan
    pr-responder) echo "33" ;;  # yellow
    pr-verifier|verifier) echo "32" ;;  # green
    researcher)   echo "34" ;;  # blue
    *)            echo "37" ;;  # white
  esac
}

echo ""
printf "\033[1m─── pepper agent monitor ─────────────────────────────── (EST)\033[0m\n"
echo ""

format_line() {
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    # Parse JSON
    ts_utc=$(echo "$line" | jq -r '.ts // empty' 2>/dev/null)
    [ -z "$ts_utc" ] && continue
    agent=$(echo "$line" | jq -r '.agent // "?"' 2>/dev/null)
    event=$(echo "$line" | jq -r '.event // "?"' 2>/dev/null)
    detail=$(echo "$line" | jq -r '.detail // empty' 2>/dev/null)
    cost=$(echo "$line" | jq -r '.cost_usd // empty' 2>/dev/null)
    duration=$(echo "$line" | jq -r '.duration_s // empty' 2>/dev/null)

    # Convert UTC to EST: parse to epoch, then format in local TZ
    epoch=$(date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$ts_utc" "+%s" 2>/dev/null || echo "")
    if [ -n "$epoch" ]; then
      ts_local=$(TZ="$TZ_OFFSET" date -j -r "$epoch" "+%I:%M:%S%p" 2>/dev/null | tr '[:upper:]' '[:lower:]')
    else
      ts_local=$(echo "$ts_utc" | cut -c12-19)
    fi

    # Format cost (2 decimal places)
    [ -n "$cost" ] && cost=$(printf "%.2f" "$cost" 2>/dev/null || echo "$cost")

    # Format duration as Xm Ys
    dur_fmt=""
    if [ -n "$duration" ] && [ "$duration" != "null" ]; then
      dur_int=$(printf "%.0f" "$duration" 2>/dev/null || echo "$duration")
      if [ "$dur_int" -ge 60 ] 2>/dev/null; then
        dur_fmt="$((dur_int / 60))m $((dur_int % 60))s"
      else
        dur_fmt="${dur_int}s"
      fi
    fi

    # Agent identity
    icon=$(icon_for "$agent")
    acol=$(color_for "$agent")

    # Skip noisy pepper events in replay (collapse them)
    case "$event" in
      pepper|pepper-fail)
        # Only show pepper events in live mode, not replay
        if [ "$REPLAY" = true ]; then continue; fi
        printf "\033[2m%s  \033[${acol}m[%s]\033[0;2m %-12s %s %s\033[0m\n" "$ts_local" "$icon" "$agent" "$event" "$detail"
        continue
        ;;
    esac

    case "$event" in
      started)
        printf "%s  \033[${acol}m[%s]\033[0m %-12s \033[1;34m%-9s\033[0m %s\n" "$ts_local" "$icon" "$agent" "STARTED" "$detail"
        ;;
      branch)
        printf "%s  \033[${acol}m[%s]\033[0m %-12s \033[0;36m%-9s\033[0m %s\n" "$ts_local" "$icon" "$agent" "BRANCH" "$detail"
        ;;
      commit)
        printf "%s  \033[${acol}m[%s]\033[0m %-12s \033[0;33m%-9s\033[0m %s\n" "$ts_local" "$icon" "$agent" "COMMIT" "$detail"
        ;;
      push)
        printf "%s  \033[${acol}m[%s]\033[0m %-12s \033[0;35m%-9s\033[0m %s\n" "$ts_local" "$icon" "$agent" "PUSH" "$detail"
        ;;
      pr)
        url=$(echo "$line" | jq -r '.url // empty' 2>/dev/null)
        printf "%s  \033[${acol}m[%s]\033[0m %-12s \033[1;32m%-9s\033[0m %s %s\n" "$ts_local" "$icon" "$agent" "PR" "$detail" "$url"
        ;;
      done)
        printf "%s  \033[${acol}m[%s]\033[0m %-12s \033[1;32m%-9s\033[0m \$%s · %s\n" "$ts_local" "$icon" "$agent" "DONE" "$cost" "$dur_fmt"
        ;;
      failed)
        printf "%s  \033[${acol}m[%s]\033[0m %-12s \033[1;31m%-9s\033[0m %s" "$ts_local" "$icon" "$agent" "FAILED" "$detail"
        [ -n "$cost" ] && [ "$cost" != "0.00" ] && printf " · \$%s" "$cost"
        [ -n "$dur_fmt" ] && printf " · %s" "$dur_fmt"
        echo ""
        ;;
      timeout)
        printf "%s  \033[${acol}m[%s]\033[0m %-12s \033[1;31m%-9s\033[0m %s · \$%s\n" "$ts_local" "$icon" "$agent" "TIMEOUT" "$detail" "$cost"
        ;;
      killed)
        printf "%s  \033[${acol}m[%s]\033[0m %-12s \033[1;31m%-9s\033[0m %s\n" "$ts_local" "$icon" "$agent" "KILLED" "$detail"
        ;;
      build)
        printf "%s  \033[${acol}m[%s]\033[0m %-12s \033[0;32m%-9s\033[0m %s\n" "$ts_local" "$icon" "$agent" "BUILD" "$detail"
        ;;
      build-fail)
        printf "%s  \033[${acol}m[%s]\033[0m %-12s \033[1;31m%-9s\033[0m %s\n" "$ts_local" "$icon" "$agent" "BUILD X" "$detail"
        ;;
      *)
        printf "%s  \033[${acol}m[%s]\033[0m %-12s %-9s %s\n" "$ts_local" "$icon" "$agent" "$event" "$detail"
        ;;
    esac
  done
}

if [ "$REPLAY" = true ]; then
  if [ ! -f "$EVENTS" ]; then
    echo "No events file found at $EVENTS"
    exit 1
  fi
  cat "$EVENTS" | format_line
  echo ""
  printf "\033[1m─────────────────────────────────────────────────────────\033[0m\n"
else
  if [ ! -f "$EVENTS" ]; then
    touch "$EVENTS"
  fi
  tail -n 0 -f "$EVENTS" 2>/dev/null | format_line
fi

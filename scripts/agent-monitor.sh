#!/bin/bash
# scripts/agent-monitor.sh — live agent event dashboard
# Usage:
#   ./scripts/agent-monitor.sh            # live tail (new events only)
#   ./scripts/agent-monitor.sh --replay   # dump full history

EVENTS="build/logs/events.jsonl"
REPLAY=false

if [ "${1:-}" = "--replay" ]; then
  REPLAY=true
  [ -n "${2:-}" ] && EVENTS="$2"
elif [ -n "${1:-}" ]; then
  EVENTS="$1"
fi

echo "─── pepper agent monitor ───────────────────────────────"
echo ""

format_line() {
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    ts=$(echo "$line" | jq -r '.ts // empty' 2>/dev/null | cut -c12-19)
    agent=$(echo "$line" | jq -r '.agent // "?"' 2>/dev/null)
    event=$(echo "$line" | jq -r '.event // "?"' 2>/dev/null)
    detail=$(echo "$line" | jq -r '.detail // empty' 2>/dev/null)
    cost=$(echo "$line" | jq -r '.cost_usd // empty' 2>/dev/null)
    duration=$(echo "$line" | jq -r '.duration_s // empty' 2>/dev/null)

    case "$event" in
      started)  printf "%s  %-9s \033[1;34mSTARTED\033[0m   %s\n" "$ts" "$agent" "$detail" ;;
      branch)   printf "%s  %-9s \033[0;36mBRANCH\033[0m    %s\n" "$ts" "$agent" "$detail" ;;
      commit)   printf "%s  %-9s \033[0;33mCOMMIT\033[0m    %s\n" "$ts" "$agent" "$detail" ;;
      push)     printf "%s  %-9s \033[0;35mPUSH\033[0m      %s\n" "$ts" "$agent" "$detail" ;;
      pr)       printf "%s  %-9s \033[1;32mPR\033[0m        %s %s\n" "$ts" "$agent" "$detail" "$(echo "$line" | jq -r '.url // empty' 2>/dev/null)" ;;
      done)     printf "%s  %-9s \033[1;32mDONE\033[0m      \$%s · %ss\n" "$ts" "$agent" "$cost" "$duration" ;;
      failed)   printf "%s  %-9s \033[1;31mFAILED\033[0m    %s · \$%s · %ss\n" "$ts" "$agent" "$detail" "$cost" "$duration" ;;
      timeout)  printf "%s  %-9s \033[1;31mTIMEOUT\033[0m   %s · \$%s\n" "$ts" "$agent" "$detail" "$cost" ;;
      killed)   printf "%s  %-9s \033[1;31mKILLED\033[0m    %s\n" "$ts" "$agent" "$detail" ;;
      build)    printf "%s  %-9s \033[0;32mBUILD\033[0m     %s\n" "$ts" "$agent" "$detail" ;;
      build-fail) printf "%s  %-9s \033[1;31mBUILD ✗\033[0m   %s\n" "$ts" "$agent" "$detail" ;;
      sim-launch) printf "%s  %-9s \033[0;36mSIM\033[0m       launched %s\n" "$ts" "$agent" "$detail" ;;
      sim-install) printf "%s  %-9s \033[0;36mSIM\033[0m       %s\n" "$ts" "$agent" "$detail" ;;
      pepper)   printf "%s  %-9s \033[0;34mPEPPER\033[0m    %s\n" "$ts" "$agent" "$detail" ;;
      pepper-fail) printf "%s  %-9s \033[1;31mPEPPER ✗\033[0m  %s\n" "$ts" "$agent" "$detail" ;;
      *)        printf "%s  %-9s %s  %s\n" "$ts" "$agent" "$event" "$detail" ;;
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
  echo "─────────────────────────────────────────────────────────"
else
  if [ ! -f "$EVENTS" ]; then
    touch "$EVENTS"
  fi
  tail -n 0 -f "$EVENTS" 2>/dev/null | format_line
fi

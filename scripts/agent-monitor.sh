#!/bin/bash
# scripts/agent-monitor.sh — live agent event dashboard
# Usage:
#   ./scripts/agent-monitor.sh            # live tail (new events only)
#   ./scripts/agent-monitor.sh --replay   # dump full history

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

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
    groomer)      echo "G" ;;
    conflict-resolver) echo "C" ;;
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
    groomer)      echo "37" ;;  # white
    conflict-resolver) echo "36" ;; # cyan
    *)            echo "37" ;;  # white
  esac
}

# ─── Status banner ──────────────────────────────────────────────
print_banner() {
  local BOLD="\033[1m" DIM="\033[2m" NC="\033[0m"
  local GREEN="\033[32m" RED="\033[31m" YELLOW="\033[33m" CYAN="\033[36m"

  echo ""
  printf "${BOLD}─── pepper agent monitor ─────────────────────────────── (EST)${NC}\n"

  # Heartbeat status
  if [ -f "build/logs/heartbeat.pid" ] && kill -0 "$(cat build/logs/heartbeat.pid 2>/dev/null)" 2>/dev/null; then
    printf "  ${GREEN}heartbeat running${NC} (PID $(cat build/logs/heartbeat.pid))\n"
  else
    printf "  ${DIM}heartbeat not running${NC}\n"
  fi

  # Active agents
  local active=""
  for lock in build/logs/.lock-*; do
    [ -f "$lock" ] || continue
    local lpid atype
    lpid=$(cat "$lock" 2>/dev/null)
    atype=$(basename "$lock" | sed 's/^\.lock-//; s/-[0-9]*$//')
    if kill -0 "$lpid" 2>/dev/null; then
      local acol
      acol=$(color_for "$atype")
      active="${active}  \033[${acol}m${atype}\033[0m(${lpid})"
    fi
  done
  if [ -n "$active" ]; then
    printf "  active:${active}\n"
  else
    printf "  ${DIM}no agents running${NC}\n"
  fi

  # Today's stats from events.jsonl
  if [ -f "$EVENTS" ]; then
    local today
    today=$(date -u +%Y-%m-%d)
    python3 -c "
import json, sys
today = '$today'
events = []
with open('$EVENTS') as f:
    for line in f:
        line = line.strip()
        if not line: continue
        try: events.append(json.loads(line))
        except: continue

today_events = [e for e in events if e.get('ts','').startswith(today)]
started = len([e for e in today_events if e.get('event') == 'started'])
done = len([e for e in today_events if e.get('event') == 'done'])
failed = len([e for e in today_events if e.get('event') in ('failed','timeout')])
total_cost = sum(float(e.get('cost_usd', 0)) for e in today_events if e.get('event') in ('done','failed','timeout','killed'))
prs = len([e for e in today_events if e.get('event') == 'pr'])
commits = len([e for e in today_events if e.get('event') == 'commit'])
total_bytes = sum(int(e.get('bytes', 0)) for e in today_events if e.get('event') in ('read','grep','glob','pepper','gh','build'))

def fmt_bytes(b):
    if b >= 1_000_000: return f'{b/1_000_000:.1f}MB'
    if b >= 1_000: return f'{b/1_000:.1f}KB'
    return f'{b}B'

# All-time stats
all_started = len([e for e in events if e.get('event') == 'started'])
all_prs = len([e for e in events if e.get('event') == 'pr'])
all_cost = sum(float(e.get('cost_usd', 0)) for e in events if e.get('event') in ('done','failed','timeout','killed'))

print(f'  \033[1mtoday\033[0m  {started} runs ({done} ok, {failed} fail) · {commits} commits · {prs} PRs · \${total_cost:.2f}', end='')
if total_bytes > 0:
    print(f' · {fmt_bytes(total_bytes)} context')
else:
    print()
print(f'  \033[2mall-time  {all_started} runs · {all_prs} PRs · \${all_cost:.2f}\033[0m')
" 2>/dev/null || true
  fi

  # Kill switch
  if [ -f ".pepper-kill" ]; then
    printf "  ${RED}KILL SWITCH ACTIVE${NC}\n"
  fi

  printf "${BOLD}─────────────────────────────────────────────────────────────${NC}\n"
  echo ""
}

format_line() {
  # Track per-session byte accumulation for end-of-session summaries
  declare -A session_bytes 2>/dev/null || true
  declare -A session_reads 2>/dev/null || true

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

    # Accumulate bytes per session for summaries
    bytes=$(echo "$line" | jq -r '.bytes // empty' 2>/dev/null)
    file=$(echo "$line" | jq -r '.file // empty' 2>/dev/null)
    if [ -n "$bytes" ] && [ "$bytes" != "0" ] && [ "$bytes" != "null" ]; then
      cur=${session_bytes[$agent]:-0}
      session_bytes[$agent]=$(( cur + bytes )) 2>/dev/null || true
    fi
    if [ "$event" = "read" ]; then
      cur=${session_reads[$agent]:-0}
      session_reads[$agent]=$(( cur + 1 )) 2>/dev/null || true
    fi

    # Reset counters on session start
    if [ "$event" = "started" ]; then
      session_bytes[$agent]=0 2>/dev/null || true
      session_reads[$agent]=0 2>/dev/null || true
    fi

    # Skip noisy tool-level events in replay (show in live mode only)
    case "$event" in
      pepper|pepper-fail|read|edit|write|grep|glob|gh)
        if [ "$REPLAY" = true ]; then continue; fi
        # In live mode, show with file/pattern info
        extra=""
        [ -n "$file" ] && extra="$(basename "$file")"
        [ -n "$detail" ] && [ -z "$extra" ] && extra="$detail"
        [ -n "$bytes" ] && [ "$bytes" != "0" ] && extra="$extra (${bytes}B)"
        printf "\033[2m%s  \033[${acol}m[%s]\033[0;2m %-12s %-9s %s\033[0m\n" "$ts_local" "$icon" "$agent" "$event" "$extra"
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
        # Enrich with context stats from this session
        ctx_info=""
        sb=${session_bytes[$agent]:-0} 2>/dev/null || sb=0
        sr=${session_reads[$agent]:-0} 2>/dev/null || sr=0
        if [ "$sb" -gt 0 ] 2>/dev/null; then
          if [ "$sb" -ge 1000000 ]; then
            ctx_info=" · $(echo "scale=1; $sb / 1000000" | bc)MB ctx"
          elif [ "$sb" -ge 1000 ]; then
            ctx_info=" · $(echo "scale=1; $sb / 1000" | bc)KB ctx"
          else
            ctx_info=" · ${sb}B ctx"
          fi
          [ "$sr" -gt 0 ] && ctx_info="${ctx_info} (${sr} reads)"
        fi
        printf "%s  \033[${acol}m[%s]\033[0m %-12s \033[1;32m%-9s\033[0m \$%s · %s%s\n" "$ts_local" "$icon" "$agent" "DONE" "$cost" "$dur_fmt" "$ctx_info"
        session_bytes[$agent]=0 2>/dev/null || true
        session_reads[$agent]=0 2>/dev/null || true
        ;;
      failed)
        printf "%s  \033[${acol}m[%s]\033[0m %-12s \033[1;31m%-9s\033[0m %s" "$ts_local" "$icon" "$agent" "FAILED" "$detail"
        [ -n "$cost" ] && [ "$cost" != "0.00" ] && printf " · \$%s" "$cost"
        [ -n "$dur_fmt" ] && printf " · %s" "$dur_fmt"
        echo ""
        session_bytes[$agent]=0 2>/dev/null || true
        session_reads[$agent]=0 2>/dev/null || true
        ;;
      timeout)
        printf "%s  \033[${acol}m[%s]\033[0m %-12s \033[1;31m%-9s\033[0m %s · \$%s\n" "$ts_local" "$icon" "$agent" "TIMEOUT" "$detail" "$cost"
        session_bytes[$agent]=0 2>/dev/null || true
        session_reads[$agent]=0 2>/dev/null || true
        ;;
      killed)
        printf "%s  \033[${acol}m[%s]\033[0m %-12s \033[1;31m%-9s\033[0m %s\n" "$ts_local" "$icon" "$agent" "KILLED" "$detail"
        session_bytes[$agent]=0 2>/dev/null || true
        session_reads[$agent]=0 2>/dev/null || true
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
  print_banner
  cat "$EVENTS" | format_line
  echo ""
  printf "\033[1m─────────────────────────────────────────────────────────────\033[0m\n"
else
  if [ ! -f "$EVENTS" ]; then
    touch "$EVENTS"
  fi
  print_banner
  tail -n 0 -f "$EVENTS" 2>/dev/null | format_line
fi

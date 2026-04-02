#!/bin/bash
set -euo pipefail

# scripts/agent-runner.sh — launch an autonomous Pepper agent
# Usage: ./scripts/agent-runner.sh <type>
# Example: ./scripts/agent-runner.sh bugfix

TYPE="${1:?Usage: agent-runner.sh <type>}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

# Shared lockfile helpers (PID-reuse-safe liveness checks)
source "$REPO_ROOT/scripts/lib/lockfile.sh"

EVENTS="$REPO_ROOT/build/logs/events.jsonl"
mkdir -p build/logs

# Rotate events.jsonl if >1MB — keeps analysis fast, archives old data
if [ -f "$EVENTS" ] && [ "$(stat -f%z "$EVENTS" 2>/dev/null || echo 0)" -gt 1048576 ]; then
  mv "$EVENTS" "$EVENTS.$(date +%Y%m%d-%H%M%S).bak"
fi

# Startup sweep: prune orphaned worktrees that no running agent owns.
# Each running agent stores its worktree path in OUR_WORKTREE. If a worktree
# exists but no agent lockfile references it, it's orphaned.
for wt in $(git worktree list --porcelain 2>/dev/null | grep "^worktree .*/\.claude/worktrees/" | sed 's/^worktree //' || true); do
  # Check if ANY lockfile's agent is still running
  OWNED=false
  for lock in build/logs/.lock-*; do
    [ -f "$lock" ] || continue
    if lockfile_alive "$lock"; then
      OWNED=true
      break
    fi
  done
  if [ "$OWNED" = false ]; then
    git worktree remove --force "$wt" 2>/dev/null || true
  fi
done
git worktree prune 2>/dev/null || true

# Timeout: 15 minutes max per agent run
TIMEOUT_S=900

AGENT_PID=""
FINAL_EVENT_EMITTED=false
OUR_WORKTREE=""  # Track which worktree belongs to THIS agent
START=""  # Set before agent launch; empty means pre-launch exit (no safety net needed)
TRANSCRIPT=""
CLAIMED_SIM=""
SIM_WAS_BOOTED=""  # "yes" if sim was already booted when we claimed it
LOCKFILE=""  # Set after capacity check passes; empty means pre-launch exit
CLAIMED_ISSUE=""  # Issue number claimed by this agent (for cleanup on timeout)

emit() {
  local event="$1"; shift
  echo "{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"agent\":\"${TYPE}\",\"event\":\"${event}\"$*}" >> "$EVENTS"
}

emit_final() {
  FINAL_EVENT_EMITTED=true
  emit "$@"
}

# Cleanup function — runs on ANY exit (normal, error, signal, timeout)
cleanup() {
  local exit_code=$?

  # Release lockfile and sim FIRST — before any slow operations.
  # If cleanup gets killed mid-way (heartbeat SIGKILL after 2s grace),
  # these are the most important resources to release.
  rm -f "$LOCKFILE" 2>/dev/null || true

  # Shut down sim immediately — don't let it idle with dialogs open
  if [ -n "$CLAIMED_SIM" ]; then
    xcrun simctl terminate "$CLAIMED_SIM" "${APP_BUNDLE_ID:-com.pepper.testapp}" 2>/dev/null || true
    xcrun simctl shutdown "$CLAIMED_SIM" 2>/dev/null || true
    python3 -c "
import sys; sys.path.insert(0, '$REPO_ROOT/pepper_ios')
from pepper_sessions import release_simulator
release_simulator('$CLAIMED_SIM', pid=$$)
" 2>/dev/null || true
  fi

  # Kill the agent process tree if still running
  if [ -n "$AGENT_PID" ] && kill -0 "$AGENT_PID" 2>/dev/null; then
    echo "Cleaning up agent process $AGENT_PID..."
    kill -TERM "$AGENT_PID" 2>/dev/null || true
    sleep 2
    kill -9 "$AGENT_PID" 2>/dev/null || true
    # Also kill any child processes (swift-frontend, xcodebuild, etc.)
    pkill -P "$AGENT_PID" 2>/dev/null || true
  fi

  # Worktree cleanup — only remove OUR worktree, not sibling agents'
  if [ -n "$OUR_WORKTREE" ]; then
    git worktree remove --force "$OUR_WORKTREE" 2>/dev/null || true
  fi

  # Release claimed issue — remove in-progress label if agent didn't open a PR
  if [ -n "$CLAIMED_ISSUE" ]; then
    OPEN_PR=$(gh pr list --repo skwallace36/Pepper-private --state open --search "Fixes #$CLAIMED_ISSUE" \
      --json number --jq 'length' 2>/dev/null || echo 0)
    if [ "$OPEN_PR" = "0" ]; then
      gh issue edit "$CLAIMED_ISSUE" --repo skwallace36/Pepper-private --remove-label "in-progress" 2>/dev/null || true
    fi
  fi

  # Sim already released at top of cleanup (before agent kill)
  git worktree prune 2>/dev/null || true

  # Clean up per-agent credential script
  rm -f "/tmp/pepper-askpass-$$.sh"

  # Ensure primary worktree is back on main — agents sometimes leave it on a branch
  local current_branch
  current_branch=$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "main")
  if [ "$current_branch" != "main" ]; then
    git -C "$REPO_ROOT" checkout main --quiet 2>/dev/null || true
  fi

  # Safety net: if no final event was emitted, emit one now with diagnostic info
  if [ "$FINAL_EVENT_EMITTED" = false ] && [ -n "$START" ]; then
    # Extract transcript from verbose log if it wasn't done before cleanup
    if [ ! -s "$TRANSCRIPT" ] && [ -s "$VERBOSE_LOG" ]; then
      grep '"type":"result"' "$VERBOSE_LOG" 2>/dev/null | tail -1 > "$TRANSCRIPT" 2>/dev/null || true
    fi
    local end_ts
    end_ts=$(date +%s)
    local dur=$((end_ts - START))
    local cost
    cost=$(jq -r '.total_cost_usd // 0' "$TRANSCRIPT" 2>/dev/null || echo 0)
    # Diagnose the failure reason
    local reason="unknown"
    if [ -f "$TRANSCRIPT" ] && [ ! -s "$TRANSCRIPT" ]; then
      reason="empty transcript (no output)"
    elif [ -f "$TRANSCRIPT" ]; then
      local turns result_text
      turns=$(jq -r '.num_turns // 0' "$TRANSCRIPT" 2>/dev/null || echo 0)
      result_text=$(jq -r '.result // ""' "$TRANSCRIPT" 2>/dev/null | head -c 150 | tr '\n' ' ')
      if [ "$turns" -le 3 ] && [ -n "$result_text" ]; then
        reason="early exit ($turns turns): $result_text"
      elif echo "$result_text" | grep -qi "rate limit\|429"; then
        reason="rate limited"
      else
        reason="exited after $turns turns: $result_text"
      fi
    else
      reason="no transcript file created"
    fi
    # Auth failures aren't the agent's fault — don't count toward backoff
    if echo "$reason" | grep -qi "Not logged in\|Please run /login"; then
      emit "auth-retry" ",\"detail\":\"${reason}\",\"cost_usd\":${cost},\"duration_s\":${dur}"
    else
      emit "failed" ",\"detail\":\"${reason}\",\"cost_usd\":${cost},\"duration_s\":${dur}"
    fi
  fi

  # Transcript retention: keep last 20 per type
  local transcripts
  transcripts=$(ls -1t build/logs/transcript-${TYPE}-*.json 2>/dev/null) || true
  local count=0
  if [ -n "$transcripts" ]; then
    count=$(echo "$transcripts" | wc -l | tr -d ' ')
  fi
  if [ "$count" -gt 20 ]; then
    echo "$transcripts" | tail -n +21 | xargs rm -f
  fi

  exit $exit_code
}
trap cleanup EXIT INT TERM

# Prerequisites check
MISSING=""
command -v claude &>/dev/null || MISSING="$MISSING claude"
command -v jq &>/dev/null || MISSING="$MISSING jq"
command -v gh &>/dev/null || MISSING="$MISSING gh"
if [ -n "$MISSING" ]; then
  emit "failed" ",\"detail\":\"missing prerequisites:$MISSING\""
  echo "Error: missing prerequisites:$MISSING"
  echo "Run: make setup"
  exit 1
fi
# Max concurrent instances per agent type
case "$TYPE" in
  bugfix)                MAX_INSTANCES=1 ;;
  pr-verifier)           MAX_INSTANCES=2 ;;
  builder)               MAX_INSTANCES=1 ;;
  pr-responder)          MAX_INSTANCES=1 ;;
  tester)                MAX_INSTANCES=0 ;;  # paused — use regression-tester instead
  regression-tester)     MAX_INSTANCES=1 ;;
  conflict-resolver)     MAX_INSTANCES=1 ;;
  *)                     MAX_INSTANCES=0 ;;
esac

# Count running instances of this type (PID-scoped lockfiles)
RUNNING=0
for lf in build/logs/.lock-${TYPE}-*; do
  [ -f "$lf" ] || continue
  if lockfile_alive "$lf"; then
    RUNNING=$((RUNNING + 1))
  else
    rm -f "$lf"  # stale (dead or PID reused)
  fi
done

if [ "$MAX_INSTANCES" -eq 0 ]; then
  # Intentionally paused — exit silently, don't pollute events or trigger backoff
  exit 0
fi
if [ "$RUNNING" -ge "$MAX_INSTANCES" ]; then
  emit "failed" ",\"detail\":\"${TYPE} at capacity (${RUNNING}/${MAX_INSTANCES})\""
  echo "Error: ${TYPE} at capacity (${RUNNING}/${MAX_INSTANCES}). Use 'make agent-cleanup' to force."
  exit 1
fi

# Backoff: skip if this agent type has too many consecutive failures.
# Prevents rapid retry loops when work is stuck or environment is broken.
# Same thresholds as heartbeat: 3 consecutive failures → 2.5h cooldown.
# This check lives here (not just in heartbeat) so that ALL callers —
# heartbeat, triggers, manual — get backoff protection. See #661.
BACKOFF_THRESHOLD=3
BACKOFF_WINDOW=9000  # 2.5 hours (heartbeat: 5 cycles * 1800s)

if [ -f "$EVENTS" ]; then
  IN_BACKOFF=$(python3 -c "
import json, sys
from datetime import datetime, timezone
agent_type = '$TYPE'
terminals = []
try:
    with open('$EVENTS') as f:
        for line in f:
            line = line.strip()
            if not line: continue
            try: e = json.loads(line)
            except: continue
            if e.get('agent') != agent_type: continue
            ev = e.get('event','')
            if ev in ('done','failed','timeout','killed'):
                terminals.append(e)
except FileNotFoundError:
    pass
if len(terminals) < $BACKOFF_THRESHOLD:
    print('no')
    sys.exit(0)
last_n = terminals[-$BACKOFF_THRESHOLD:]
if any(e['event'] == 'done' for e in last_n):
    print('no')
    sys.exit(0)
last_ts = last_n[-1].get('ts','')
try:
    last_dt = datetime.fromisoformat(last_ts.replace('Z','+00:00'))
    elapsed = (datetime.now(timezone.utc) - last_dt).total_seconds()
except:
    print('no')
    sys.exit(0)
print('yes' if elapsed < $BACKOFF_WINDOW else 'no')
" 2>/dev/null || echo "no")
  if [ "$IN_BACKOFF" = "yes" ]; then
    emit "skipped" ",\"detail\":\"${TYPE} in backoff (${BACKOFF_THRESHOLD}+ consecutive failures, cooldown ${BACKOFF_WINDOW}s)\""
    echo "${TYPE} in backoff (${BACKOFF_THRESHOLD}+ consecutive failures) — skipping."
    exit 0
  fi
fi

LOCKFILE="$REPO_ROOT/build/logs/.lock-${TYPE}-$$"
lockfile_write "$LOCKFILE"

if ! gh auth status &>/dev/null; then
  emit "failed" ",\"detail\":\"gh not authenticated\""
  echo "Error: gh not authenticated. Run: gh auth login"
  exit 1
fi


# Verify prompt file exists
PROMPT_FILE="scripts/prompts/${TYPE}.md"
if [ ! -f "$PROMPT_FILE" ]; then
  emit "failed" ",\"detail\":\"prompt file not found: ${PROMPT_FILE}\""
  echo "Error: prompt file not found: $PROMPT_FILE"
  exit 1
fi

# Daily budget enforcement
# Per-type: $150/day, Total: $500/day
TODAY=$(date -u +%Y-%m-%d)
sum_cost() {
  local filter="$1"
  python3 -c "
import json, sys
total = 0.0
with open('$EVENTS') as f:
    for line in f:
        line = line.strip()
        if not line: continue
        try:
            e = json.loads(line)
        except: continue
        if not e.get('ts','').startswith('$TODAY'): continue
        if '$filter' == 'type' and e.get('agent') != '$TYPE': continue
        cost = e.get('cost_usd', 0)
        try: total += float(cost)
        except: pass
print(f'{total:.2f}')
" 2>/dev/null || echo "0.00"
}
TYPE_COST_TODAY=$(sum_cost "type")
TOTAL_COST_TODAY=$(sum_cost "all")

if [ "$(echo "$TYPE_COST_TODAY > 150" | bc)" = "1" ]; then
  emit "failed" ",\"detail\":\"daily budget exceeded for ${TYPE}: \$${TYPE_COST_TODAY}\""
  echo "Daily budget exceeded for ${TYPE}: \$${TYPE_COST_TODAY}/\$150. Skipping."
  exit 0
fi
if [ "$(echo "$TOTAL_COST_TODAY > 500" | bc)" = "1" ]; then
  emit "failed" ",\"detail\":\"total daily budget exceeded: \$${TOTAL_COST_TODAY}\""
  echo "Total daily budget exceeded: \$${TOTAL_COST_TODAY}/\$500. Skipping."
  exit 0
fi

emit "started" ",\"detail\":\"picking work from queue (\$${TYPE_COST_TODAY} spent today)\""

# Export env vars for hooks (PostToolUse events + wrap-up reminder)
export PEPPER_EVENTS_LOG="$EVENTS"
export PEPPER_AGENT_TYPE="$TYPE"
export PEPPER_AGENT_PID=$$
export PEPPER_WRAPUP_FILE="/tmp/pepper-agent-$$.wrapup"

# Session label — flows through to session files so `simulator action=list`
# shows which agent owns which sim.
export PEPPER_SESSION_LABEL="${PEPPER_SESSION_LABEL:-agent-${TYPE}}"

# Reset drift detection state for this session
"$REPO_ROOT/scripts/hooks/agent-drift-detector.sh" reset 2>/dev/null || true

# Disable auto-memory — agents don't need user preferences or project memories
export CLAUDE_CODE_DISABLE_AUTO_MEMORY=1

# Claim a simulator — only for agent types that need one.
# Other agents (conflict-resolver, groomer, pr-responder) skip this entirely.
NEEDS_SIM=false
case "$TYPE" in
  pr-verifier|regression-tester|tester|bugfix) NEEDS_SIM=true ;;
esac

if [ "$NEEDS_SIM" = true ]; then
  # 30s timeout prevents hanging if xcrun is stuck
  CLAIMED_SIM=$(python3 -c "
import sys, signal; sys.path.insert(0, '$REPO_ROOT/pepper_ios')
signal.alarm(30)
from pepper_sessions import find_available_simulator, claim_simulator
udid = find_available_simulator()
claim_simulator(udid, label='agent-${TYPE}', pid=$$)
print(udid)
" 2>/dev/null || true)
  if [ -n "$CLAIMED_SIM" ]; then
    export SIMULATOR_ID="$CLAIMED_SIM"
    # Boot the sim if not already booted
    SIM_STATE=$(xcrun simctl list devices -j 2>/dev/null | python3 -c "
import json, sys
data = json.load(sys.stdin)
for rt, devs in data.get('devices', {}).items():
    for d in devs:
        if d.get('udid') == '$CLAIMED_SIM':
            print(d.get('state', 'Unknown'))
            sys.exit(0)
print('Unknown')
" 2>/dev/null || echo "Unknown")
    if [ "$SIM_STATE" = "Booted" ]; then
      SIM_WAS_BOOTED=yes
    else
      SIM_WAS_BOOTED=no
      echo "Booting sim $CLAIMED_SIM..."
      xcrun simctl boot "$CLAIMED_SIM" 2>/dev/null || true
      # Wait for boot to complete (max 30s)
      xcrun simctl bootstatus "$CLAIMED_SIM" -b 2>/dev/null &
      _boot_pid=$!
      for _i in $(seq 1 30); do
        kill -0 "$_boot_pid" 2>/dev/null || break
        sleep 1
      done
      kill "$_boot_pid" 2>/dev/null || true
      wait "$_boot_pid" 2>/dev/null || true
    fi
  fi
fi

# Sim health check — verify the claimed sim is responsive before launching.
# A frozen sim (stuck on springboard) wastes the entire agent session.
if [ -n "$CLAIMED_SIM" ]; then
  xcrun simctl spawn "$CLAIMED_SIM" launchctl print system >/dev/null 2>&1 &
  _hc_pid=$!
  _hc_ok=false
  for _i in 1 2 3 4 5; do
    if ! kill -0 "$_hc_pid" 2>/dev/null; then
      wait "$_hc_pid" 2>/dev/null && _hc_ok=true
      break
    fi
    sleep 1
  done
  if [ "$_hc_ok" = false ]; then
    kill "$_hc_pid" 2>/dev/null || true
    wait "$_hc_pid" 2>/dev/null || true
    echo "Sim $CLAIMED_SIM unresponsive — rebooting..."
    xcrun simctl shutdown "$CLAIMED_SIM" 2>/dev/null || true
    xcrun simctl boot "$CLAIMED_SIM" 2>/dev/null || true
    sleep 3
  fi

  # Agents always use the test app — never a real app.
  # This prevents agents from interacting with apps on other machines or work apps.
  export APP_BUNDLE_ID="com.pepper.testapp"
  BUNDLE_ID="com.pepper.testapp"

  # Grant ALL permissions at once — covers every service simctl supports.
  # "grant all" is simpler and future-proof vs maintaining a perm list.
  xcrun simctl privacy "$CLAIMED_SIM" grant all "$BUNDLE_ID" 2>/dev/null || true
fi

# Agent GitHub identity — each agent type maps to a machine user account.
# Concurrent instances of the same type share the same identity.
# The .env file has AGENT{N}_GITHUB_USERNAME, _EMAIL, _PAT for each.
source_env() {
  [ -f "$REPO_ROOT/.env" ] || return
  while IFS='=' read -r key value; do
    [[ "$key" =~ ^#.*$ || -z "$key" ]] && continue
    # API keys are read but not exported — scoped to the claude process at launch time.
    if [[ "$key" == "ANTHROPIC_API_KEY" || "$key" == "PEPPER_AGENT_API_KEY" ]]; then
      eval "$key=\"$value\""
    # Don't let .env override the agent's forced test app bundle ID.
    elif [[ "$key" == "APP_BUNDLE_ID" && "${APP_BUNDLE_ID:-}" == "com.pepper.testapp" ]]; then
      continue
    else
      export "$key"="$value"
    fi
  done < "$REPO_ROOT/.env"
}
source_env

# Map agent type → machine user number (1-indexed)
case "$TYPE" in
  bugfix)            AGENT_NUM=1 ;;  # 1 instance  → account 1
  builder)           AGENT_NUM=2 ;;  # 2 instances → accounts 2,3
  pr-verifier)       AGENT_NUM=4 ;;  # 2 instances → accounts 4,5
  pr-responder)      AGENT_NUM=6 ;;  # 1 instance  → account 6
  tester|regression-tester) AGENT_NUM=7 ;;  # 1 instance  → account 7
  conflict-resolver) AGENT_NUM=8 ;;  # 1 instance  → account 8
  researcher)        AGENT_NUM=9 ;;  # 1 instance  → account 9
  groomer)           AGENT_NUM=10 ;; # 1 instance  → account 10
  *)                 AGENT_NUM=10 ;; # fallback shares groomer
esac

# For multi-instance types, offset by instance count so each gets a unique identity
if [ "$MAX_INSTANCES" -gt 1 ] && [ "$RUNNING" -gt 0 ]; then
  AGENT_NUM=$((AGENT_NUM + RUNNING))
fi

# Resolve credentials from env
AGENT_USER_VAR="AGENT${AGENT_NUM}_GITHUB_USERNAME"
AGENT_EMAIL_VAR="AGENT${AGENT_NUM}_GITHUB_EMAIL"
AGENT_PAT_VAR="AGENT${AGENT_NUM}_GITHUB_PAT"

AGENT_USERNAME="${!AGENT_USER_VAR:-}"
AGENT_EMAIL="${!AGENT_EMAIL_VAR:-}"
AGENT_PAT="${!AGENT_PAT_VAR:-}"

if [ -n "$AGENT_USERNAME" ]; then
  export GIT_AUTHOR_NAME="$AGENT_USERNAME"
  export GIT_AUTHOR_EMAIL="$AGENT_EMAIL"
  export GIT_COMMITTER_NAME="$AGENT_USERNAME"
  export GIT_COMMITTER_EMAIL="$AGENT_EMAIL"
  # Set GH_TOKEN so gh CLI operations (PRs, comments) use the machine user
  export GH_TOKEN="$AGENT_PAT"
  # Per-agent credential script (avoids global git config race between concurrent agents)
  ASKPASS_SCRIPT="/tmp/pepper-askpass-$$.sh"
  cat > "$ASKPASS_SCRIPT" <<ASKEOF
#!/bin/sh
case "\$1" in
  Username*) echo "$AGENT_USERNAME" ;;
  Password*) echo "$AGENT_PAT" ;;
esac
ASKEOF
  chmod +x "$ASKPASS_SCRIPT"
  export GIT_ASKPASS="$ASKPASS_SCRIPT"
  export GIT_TERMINAL_PROMPT=0
  emit "identity" ",\"agent_num\":${AGENT_NUM},\"username\":\"${AGENT_USERNAME}\""
else
  # Fallback to generic identity if no machine user configured
  export GIT_AUTHOR_NAME="pepper-${TYPE}-agent"
  export GIT_AUTHOR_EMAIL="pepper-${TYPE}-agent@noreply.pepper.dev"
  export GIT_COMMITTER_NAME="pepper-${TYPE}-agent"
  export GIT_COMMITTER_EMAIL="pepper-${TYPE}-agent@noreply.pepper.dev"
fi

# Ensure agent pushes and gh CLI target the private repo.
# origin should already point to Pepper-private, but GH_REPO is explicit.
export GH_REPO="skwallace36/Pepper-private"

START=$(date +%s)
TRANSCRIPT="build/logs/transcript-${TYPE}-${START}.json"
VERBOSE_LOG="build/logs/verbose-${TYPE}-${START}.log"

PROMPT=$(cat "$PROMPT_FILE")

# Per-agent budget (Opus agents get more headroom since it costs more per token)
case "$TYPE" in
  pr-verifier) BUDGET=5.00 ;;
  tester|regression-tester) BUDGET=5.00 ;;
  bugfix)   BUDGET=5.00 ;;
  builder)  BUDGET=5.00 ;;
  pr-responder) BUDGET=5.00 ;;
  researcher) BUDGET=5.00 ;;
  groomer)  BUDGET=3.00 ;;
  conflict-resolver) BUDGET=1.00 ;;
  *)        BUDGET=2.00 ;;
esac

# Model routing — Opus for reasoning-heavy work, Sonnet for mechanical/scripted tasks
case "$TYPE" in
  bugfix|builder|researcher|pr-verifier|pr-responder|regression-tester) MODEL="opus" ;;
  tester|groomer|conflict-resolver)                                    MODEL="sonnet" ;;
  *)                                                  MODEL="sonnet" ;;
esac

# Serialize worktree creation across concurrent agents.
# Claude's --worktree flag runs `git worktree add` internally, which locks .git/config.
# Without serialization, concurrent launches race and fail.
WORKTREE_LOCK="$REPO_ROOT/build/logs/.worktree-create.lock"
exec 8>"$WORKTREE_LOCK"
if command -v flock &>/dev/null; then
  flock -w 120 8 || { echo "Timed out waiting for worktree lock"; exit 1; }
else
  # macOS: lockf with 120s timeout — enough for ~6 agents queued at ~15s each
  lockf -s -t 120 8 || { echo "Timed out waiting for worktree lock"; exit 1; }
fi

# Snapshot worktrees before launch so we can identify ours
WORKTREES_BEFORE=$(git worktree list --porcelain 2>/dev/null | grep "^worktree .*/\.claude/worktrees/" | sed 's/^worktree //' | sort || true)

# Launch the agent in background so we can enforce timeout
# --name is our stable marker for process identification (agents-stop uses pgrep on it)
# Stream-json gives turn-by-turn verbose log; we extract the final result line for the transcript.
# PEPPER_AGENT_API_KEY → ANTHROPIC_API_KEY scoped to only this claude process.
# Export API key only for the claude subprocess if set.
# Use subshell export so it doesn't leak into the runner's environment.
if [ -n "${PEPPER_AGENT_API_KEY:-}" ]; then
  export ANTHROPIC_API_KEY="$PEPPER_AGENT_API_KEY"
fi
claude -p \
  "You are the ${TYPE} agent. Follow your instructions." \
  --append-system-prompt "$PROMPT" \
  --model "$MODEL" \
  --max-budget-usd "$BUDGET" \
  --output-format stream-json \
  --verbose \
  --worktree \
  --name "pepper-agent-${TYPE}" \
  8>&- > "$VERBOSE_LOG" 2>&1 &
AGENT_PID=$!

# Identify which worktree was created for this agent.
# Poll until it appears (max 15s), then release the lock so the next agent can start.
for _wait in 1 2 3 4 5; do
  sleep "$_wait"
  WORKTREES_AFTER=$(git worktree list --porcelain 2>/dev/null | grep "^worktree .*/\.claude/worktrees/" | sed 's/^worktree //' | sort || true)
  OUR_WORKTREE=$(comm -13 <(echo "$WORKTREES_BEFORE") <(echo "$WORKTREES_AFTER") | head -1)
  [ -n "$OUR_WORKTREE" ] && break
done
# Release worktree creation lock — next agent can now create theirs
exec 8>&-

# Symlink .venv into worktree so MCP servers can resolve ./.venv/bin/python3
if [ -n "$OUR_WORKTREE" ] && [ -d "$REPO_ROOT/.venv" ] && [ ! -e "$OUR_WORKTREE/.venv" ]; then
  ln -s "$REPO_ROOT/.venv" "$OUR_WORKTREE/.venv"
fi

# Wait with timeout
TIMED_OUT=false
ELAPSED=0
# Quick check: if agent dies in first 5 seconds total (2s above + 1s here)
sleep 1
if ! kill -0 "$AGENT_PID" 2>/dev/null; then
  wait "$AGENT_PID" 2>/dev/null
  EXIT_CODE=$?
  AGENT_PID=""
  grep '"type":"result"' "$VERBOSE_LOG" 2>/dev/null | tail -1 > "$TRANSCRIPT" || true
  END=$(date +%s)
  DURATION=$((END - START))
  COST=$(jq -r '.total_cost_usd // .cost_usd // 0' "$TRANSCRIPT" 2>/dev/null || echo 0)
  DETAIL=$(head -c 200 "$VERBOSE_LOG" 2>/dev/null | tr '\n' ' ' || echo "agent died immediately")
  if echo "$DETAIL" | grep -qi "Not logged in"; then
    emit "auth-retry" ",\"detail\":\"Claude CLI auth expired on startup\",\"cost_usd\":${COST},\"duration_s\":${DURATION}"
  else
    emit_final "failed" ",\"detail\":\"agent died in <3s (auth? crash?): $(echo "$DETAIL" | jq -Rs '.'| head -c 150)\",\"cost_usd\":${COST},\"duration_s\":${DURATION}"
  fi
  echo "Agent died immediately. Transcript: $TRANSCRIPT"
  exit 1
fi
WRAPUP_SENT=false
WRAPUP_AT=$(( TIMEOUT_S * 80 / 100 ))  # 80% of timeout
while kill -0 "$AGENT_PID" 2>/dev/null; do
  sleep 5
  ELAPSED=$(( $(date +%s) - START ))
  # Signal wrap-up at 80% — hook will inject reminder on next tool call
  if [ "$WRAPUP_SENT" = false ] && [ "$ELAPSED" -ge "$WRAPUP_AT" ]; then
    echo "wrap-up" > "$PEPPER_WRAPUP_FILE"
    WRAPUP_SENT=true
    echo "Wrap-up signal sent (${ELAPSED}s / ${TIMEOUT_S}s)"
  fi
  if [ "$ELAPSED" -ge "$TIMEOUT_S" ]; then
    TIMED_OUT=true
    echo "Timeout (${TIMEOUT_S}s) — killing agent..."
    kill -TERM "$AGENT_PID" 2>/dev/null || true
    sleep 3
    kill -9 "$AGENT_PID" 2>/dev/null || true
    pkill -P "$AGENT_PID" 2>/dev/null || true
    break
  fi
done
rm -f "$PEPPER_WRAPUP_FILE" 2>/dev/null

wait "$AGENT_PID" 2>/dev/null
EXIT_CODE=$?
AGENT_PID=""  # Clear so cleanup doesn't try to kill again

# Extract final result line from stream-json verbose log into transcript
# The result line has {"type":"result",...} with the same shape as --output-format json
grep '"type":"result"' "$VERBOSE_LOG" 2>/dev/null | tail -1 > "$TRANSCRIPT" || true

END=$(date +%s)
DURATION=$((END - START))

# Extract claimed issue number from events (for cleanup on timeout/failure)
CLAIMED_ISSUE=$(python3 -c "
import json
start_ts = '$(date -u -r $START +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d @$START +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo '')'
try:
    with open('$EVENTS') as f:
        for line in f:
            try:
                e = json.loads(line.strip())
                if e.get('agent') == '$TYPE' and e.get('event') == 'task-claimed' and e.get('ts','') >= start_ts:
                    print(e.get('detail','').split()[0].lstrip('#'))
                    break
            except: pass
except: pass
" 2>/dev/null || true)

# Handle empty transcripts — CLI crashed before writing output
if [ ! -s "$TRANSCRIPT" ]; then
  emit "auth-retry" ",\"detail\":\"empty transcript — CLI may have crashed or session expired\",\"duration_s\":$((END - START))"
  echo "Empty transcript. Transcript: $TRANSCRIPT"
  exit 0  # Don't count as failure — prevents backoff
fi

# Extract cost from transcript
COST=$(jq -r '.total_cost_usd // .cost_usd // 0' "$TRANSCRIPT" 2>/dev/null || echo 0)

# Emit session-summary: aggregate stats from events emitted during this run
python3 - "$EVENTS" "$TYPE" "$START" "$TRANSCRIPT" <<'SUMMARY_EOF'
import json, sys
from collections import defaultdict
from datetime import datetime, timezone

events_file, agent = sys.argv[1], sys.argv[2]
start_epoch, transcript = int(sys.argv[3]), sys.argv[4]
start_ts = datetime.fromtimestamp(start_epoch, tz=timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')

events = []
try:
    with open(events_file) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                e = json.loads(line)
            except json.JSONDecodeError:
                continue
            if e.get('agent') != agent or e.get('ts', '') < start_ts:
                continue
            events.append(e)
except FileNotFoundError:
    sys.exit(0)

lifecycle = ('started', 'done', 'failed', 'timeout', 'killed', 'session-summary')
tool_calls = defaultdict(int)
bytes_read = 0
bytes_written = 0
file_reads = defaultdict(int)

for e in events:
    ev = e.get('event', '')
    if ev in lifecycle:
        continue
    tool_calls[ev] += 1
    b = 0
    try:
        b = int(e.get('bytes', 0))
    except (ValueError, TypeError):
        pass
    if ev == 'read':
        bytes_read += b
        file_reads[e.get('file', '?')] += 1
    elif ev == 'write':
        bytes_written += b

total_reads = sum(file_reads.values())
rereads = sum(max(0, c - 1) for c in file_reads.values())

hit_compact = False
try:
    with open(transcript) as f:
        content = f.read()
        hit_compact = '"compact"' in content
except (FileNotFoundError, OSError):
    pass

summary = {
    "ts": datetime.now(tz=timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
    "agent": agent,
    "event": "session-summary",
    "bytes_read": bytes_read,
    "bytes_written": bytes_written,
    "file_reads": total_reads,
    "file_rereads": rereads,
    "tool_calls": dict(tool_calls),
    "hit_compact": hit_compact,
}

with open(events_file, 'a') as f:
    f.write(json.dumps(summary, separators=(',', ':')) + '\n')
SUMMARY_EOF

# Extract turn count and exit reason from transcript for richer events
TURNS=$(jq -r '.num_turns // 0' "$TRANSCRIPT" 2>/dev/null || echo 0)
EXIT_REASON=$(jq -r '.result // ""' "$TRANSCRIPT" 2>/dev/null | head -c 200 | tr '\n' ' ' | jq -Rs '.' 2>/dev/null || echo '""')

# Detect unproductive runs: short duration + no commits/pushes
# "idle" = agent correctly found no work (not a failure, skip backoff)
# "failed" = agent had work but didn't accomplish anything (triggers backoff)
UNPRODUCTIVE=false
UNPRODUCTIVE_IDLE=false
UNPRODUCTIVE_REASON=""
# Read-only agents (pr-verifier, pr-responder, groomer, conflict-resolver) don't
# edit/commit/build — they do gh operations. Skip the unproductive check for them.
SKIP_PROD_CHECK=false
case "$TYPE" in
  pr-verifier|pr-responder|groomer|conflict-resolver) SKIP_PROD_CHECK=true ;;
esac

if [ "$SKIP_PROD_CHECK" = false ] && [ "$DURATION" -lt 120 ] && [ $EXIT_CODE -eq 0 ]; then
  PROD_STATS=$(python3 -c "
import json, sys
from datetime import datetime, timezone
start_ts = datetime.fromtimestamp($START, tz=timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
blocks = commits = pushes = edits = builds = 0
with open('$EVENTS') as f:
    for line in f:
        line = line.strip()
        if not line: continue
        try: e = json.loads(line)
        except: continue
        if e.get('agent') != '$TYPE' or e.get('ts','') < start_ts: continue
        ev = e.get('event','')
        if ev == 'guardrail-block': blocks += 1
        elif ev == 'commit': commits += 1
        elif ev == 'push': pushes += 1
        elif ev == 'edit': edits += 1
        elif ev == 'build': builds += 1
print(f'{blocks} {commits} {pushes} {edits} {builds}')
" 2>/dev/null || echo "0 0 0 0 0")
  GB_COUNT=$(echo "$PROD_STATS" | cut -d' ' -f1)
  COMMIT_COUNT=$(echo "$PROD_STATS" | cut -d' ' -f2)
  PUSH_COUNT=$(echo "$PROD_STATS" | cut -d' ' -f3)
  EDIT_COUNT=$(echo "$PROD_STATS" | cut -d' ' -f4)
  BUILD_COUNT=$(echo "$PROD_STATS" | cut -d' ' -f5)
  # Unproductive if no commits, no pushes, no edits, and no builds
  if [ "$COMMIT_COUNT" -eq 0 ] && [ "$PUSH_COUNT" -eq 0 ] && [ "$EDIT_COUNT" -eq 0 ] && [ "$BUILD_COUNT" -eq 0 ]; then
    UNPRODUCTIVE=true
    # Check if the agent legitimately found no work (idle vs broken)
    RESULT_TEXT=$(jq -r '.result // ""' "$TRANSCRIPT" 2>/dev/null | tr '[:upper:]' '[:lower:]')
    if echo "$RESULT_TEXT" | grep -qiE 'no (unclaimed|available|open|remaining) (bug|task|work|issue)|all .* (claimed|have (open )?pr)|nothing to do|no work'; then
      UNPRODUCTIVE_IDLE=true
      UNPRODUCTIVE_REASON="no work available, ${DURATION}s"
    elif [ "$GB_COUNT" -gt 0 ]; then
      UNPRODUCTIVE_REASON="${GB_COUNT} guardrail blocks, no productive actions, ${DURATION}s"
    else
      UNPRODUCTIVE_REASON="no productive actions (no edits/commits/builds), ${DURATION}s"
    fi
  fi
fi

# Detect "Not logged in" — Claude CLI session issue, not a real agent failure.
# Don't count these toward backoff — they'll resolve on their own.
NOT_LOGGED_IN=false
if jq -r '.result // ""' "$TRANSCRIPT" 2>/dev/null | grep -q 'Not logged in'; then
  NOT_LOGGED_IN=true
fi

# Emit final event based on outcome
if [ "$TIMED_OUT" = true ]; then
  emit_final "timeout" ",\"detail\":\"killed after ${TIMEOUT_S}s\",\"cost_usd\":${COST},\"duration_s\":${DURATION},\"turns\":${TURNS}"
elif [ "$NOT_LOGGED_IN" = true ]; then
  # Emit as a warning, not a failure — prevents backoff escalation
  emit "auth-retry" ",\"detail\":\"Claude CLI session expired — will retry next cycle\",\"cost_usd\":${COST},\"duration_s\":${DURATION},\"turns\":${TURNS}"
elif [ $EXIT_CODE -ne 0 ]; then
  emit_final "failed" ",\"detail\":${EXIT_REASON},\"cost_usd\":${COST},\"duration_s\":${DURATION},\"turns\":${TURNS}"
elif [ "$UNPRODUCTIVE" = true ] && [ "$UNPRODUCTIVE_IDLE" = true ]; then
  # Agent correctly found no work — emit "done" so backoff doesn't trigger
  emit_final "done" ",\"detail\":\"idle (${UNPRODUCTIVE_REASON})\",\"cost_usd\":${COST},\"duration_s\":${DURATION},\"turns\":${TURNS}"
elif [ "$UNPRODUCTIVE" = true ]; then
  emit_final "failed" ",\"detail\":\"unproductive run (${UNPRODUCTIVE_REASON})\",\"cost_usd\":${COST},\"duration_s\":${DURATION},\"turns\":${TURNS}"
else
  emit_final "done" ",\"cost_usd\":${COST},\"duration_s\":${DURATION},\"turns\":${TURNS},\"exit_reason\":${EXIT_REASON}"
fi

# Auto-label new PRs with awaiting:verifier (state machine entry point).
# Only labels PRs that have no awaiting: or verified label yet.
# Note: --author is omitted because agents push under the repo owner's GitHub
# account, not their git commit identity. Filter on unlabeled PRs only.
if [ "$TYPE" != "pr-verifier" ] && [ "$TYPE" != "pr-responder" ]; then
  for pr_num in $(gh pr list --repo skwallace36/Pepper-private --state open \
    --json number,labels --jq '.[] | select(.labels | length == 0) | .number' 2>/dev/null); do
    "$REPO_ROOT/scripts/classify-pr.sh" "$pr_num" 2>/dev/null || true
  done
fi

# No auto-chaining — heartbeat is the sole agent scheduler.
# Spawning subagents here bypassed heartbeat's backoff logic. See #661.

echo "Done. Transcript: $TRANSCRIPT  Verbose: $VERBOSE_LOG"

#!/bin/bash
set -euo pipefail

# scripts/agent-runner.sh — launch an autonomous Pepper agent
# Usage: ./scripts/agent-runner.sh <type>
# Example: ./scripts/agent-runner.sh bugfix

TYPE="${1:?Usage: agent-runner.sh <type>}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

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
    pid=$(cat "$lock" 2>/dev/null)
    if kill -0 "$pid" 2>/dev/null; then
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
SIMS_BEFORE=""

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

  # Release claimed simulator — terminate app first so the port-based
  # liveness check doesn't keep the session alive after we release it.
  if [ -n "$CLAIMED_SIM" ]; then
    BID="${APP_BUNDLE_ID:-com.pepper.testapp}"
    xcrun simctl terminate "$CLAIMED_SIM" "$BID" 2>/dev/null || true
    python3 -c "
import sys; sys.path.insert(0, '$REPO_ROOT/tools')
from pepper_sessions import release_simulator
release_simulator('$CLAIMED_SIM')
" 2>/dev/null || true
  fi

  # Sim cleanup — shut down any sims this agent booted
  if [ -n "$SIMS_BEFORE" ]; then
    SIMS_AFTER=$(xcrun simctl list devices booted -j 2>/dev/null | python3 -c "
import json, sys
devs = json.load(sys.stdin)['devices']
print(' '.join(d['udid'] for r in devs.values() for d in r if d['state'] == 'Booted'))
" 2>/dev/null || true)
    for sim in $SIMS_AFTER; do
      if ! echo "$SIMS_BEFORE" | grep -q "$sim"; then
        xcrun simctl shutdown "$sim" 2>/dev/null || true
      fi
    done
  fi
  git worktree prune 2>/dev/null || true

  # Ensure primary worktree is back on main — agents sometimes leave it on a branch
  local current_branch
  current_branch=$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "main")
  if [ "$current_branch" != "main" ]; then
    git -C "$REPO_ROOT" checkout main --quiet 2>/dev/null || true
  fi

  # Safety net: if no final event was emitted, emit one now with diagnostic info
  if [ "$FINAL_EVENT_EMITTED" = false ] && [ -n "$START" ]; then
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
    emit "failed" ",\"detail\":\"${reason}\",\"cost_usd\":${cost},\"duration_s\":${dur}"
  fi

  # Release lockfile
  rm -f "$LOCKFILE" 2>/dev/null || true

  # Transcript retention: keep last 20 per type
  local transcripts
  transcripts=$(ls -1t build/logs/transcript-${TYPE}-*.json 2>/dev/null || true)
  local count
  count=$(echo "$transcripts" | grep -c . 2>/dev/null || echo 0)
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
  pr-verifier|verifier) MAX_INSTANCES=2 ;;
  builder)              MAX_INSTANCES=1 ;;
  *)                    MAX_INSTANCES=1 ;;
esac

# Count running instances of this type (PID-scoped lockfiles)
RUNNING=0
for lf in build/logs/.lock-${TYPE}-*; do
  [ -f "$lf" ] || continue
  lpid=$(cat "$lf" 2>/dev/null)
  if kill -0 "$lpid" 2>/dev/null; then
    RUNNING=$((RUNNING + 1))
  else
    rm -f "$lf"  # stale
  fi
done

if [ "$RUNNING" -ge "$MAX_INSTANCES" ]; then
  emit "failed" ",\"detail\":\"${TYPE} at capacity (${RUNNING}/${MAX_INSTANCES})\""
  echo "Error: ${TYPE} at capacity (${RUNNING}/${MAX_INSTANCES}). Use 'make agent-cleanup' to force."
  exit 1
fi

LOCKFILE="build/logs/.lock-${TYPE}-$$"
echo $$ > "$LOCKFILE"

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
  echo "Total daily budget exceeded: \$${TOTAL_COST_TODAY}/\$300. Skipping."
  exit 0
fi

emit "started" ",\"detail\":\"picking work from queue (\$${TYPE_COST_TODAY} spent today)\""

# Export env vars for the PostToolUse hook
export PEPPER_EVENTS_LOG="$EVENTS"
export PEPPER_AGENT_TYPE="$TYPE"

# Disable auto-memory — agents don't need user preferences or project memories
export CLAUDE_CODE_DISABLE_AUTO_MEMORY=1

# Claim a simulator via pepper_sessions (flock-based, multi-agent safe)
# 30s timeout prevents hanging if xcrun is stuck
CLAIMED_SIM=$(python3 -c "
import sys, signal; sys.path.insert(0, '$REPO_ROOT/tools')
signal.alarm(30)
from pepper_sessions import find_available_simulator, claim_simulator
udid = find_available_simulator()
claim_simulator(udid, label='agent-${TYPE}')
print(udid)
" 2>/dev/null || true)
if [ -n "$CLAIMED_SIM" ]; then
  export SIMULATOR_ID="$CLAIMED_SIM"
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

  # Grant ALL permissions at once — covers every service simctl supports.
  # "grant all" is simpler and future-proof vs maintaining a perm list.
  BUNDLE_ID="${APP_BUNDLE_ID:-com.pepper.testapp}"
  xcrun simctl privacy "$CLAIMED_SIM" grant all "$BUNDLE_ID" 2>/dev/null || true
fi

# Agent git identity — agents commit as themselves, not as the user
export GIT_AUTHOR_NAME="pepper-${TYPE}-agent"
export GIT_AUTHOR_EMAIL="pepper-${TYPE}-agent@noreply.pepper.dev"
export GIT_COMMITTER_NAME="pepper-${TYPE}-agent"
export GIT_COMMITTER_EMAIL="pepper-${TYPE}-agent@noreply.pepper.dev"

# Snapshot booted sims before agent runs — shut down any new ones in cleanup
SIMS_BEFORE=$(xcrun simctl list devices booted -j 2>/dev/null | python3 -c "
import json, sys
devs = json.load(sys.stdin)['devices']
print(' '.join(d['udid'] for r in devs.values() for d in r if d['state'] == 'Booted'))
" 2>/dev/null || true)

START=$(date +%s)
TRANSCRIPT="build/logs/transcript-${TYPE}-${START}.json"

PROMPT=$(cat "$PROMPT_FILE")

# Per-agent budget (Opus agents get more headroom since it costs more per token)
case "$TYPE" in
  verifier|pr-verifier) BUDGET=5.00 ;;
  tester)   BUDGET=5.00 ;;
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
  bugfix|builder|researcher|pr-verifier|pr-responder) MODEL="opus" ;;
  tester|groomer|conflict-resolver|verifier)          MODEL="sonnet" ;;
  *)                                                  MODEL="sonnet" ;;
esac

# Snapshot worktrees before launch so we can identify ours
WORKTREES_BEFORE=$(git worktree list --porcelain 2>/dev/null | grep "^worktree .*/\.claude/worktrees/" | sed 's/^worktree //' | sort || true)

# Stagger concurrent launches — random 0-3s to avoid git worktree add race
sleep $(( RANDOM % 4 ))

# Launch the agent in background so we can enforce timeout
# --name is our stable marker for process identification (agents-stop uses pgrep on it)
claude -p \
  "You are the ${TYPE} agent. Follow your instructions." \
  --append-system-prompt "$PROMPT" \
  --model "$MODEL" \
  --max-budget-usd "$BUDGET" \
  --output-format json \
  --worktree \
  --name "pepper-agent-${TYPE}" \
  > "$TRANSCRIPT" 2>&1 &
AGENT_PID=$!

# Identify which worktree was created for this agent
sleep 2
WORKTREES_AFTER=$(git worktree list --porcelain 2>/dev/null | grep "^worktree .*/\.claude/worktrees/" | sed 's/^worktree //' | sort || true)
OUR_WORKTREE=$(comm -13 <(echo "$WORKTREES_BEFORE") <(echo "$WORKTREES_AFTER") | head -1)

# Wait with timeout
TIMED_OUT=false
ELAPSED=0
# Quick check: if agent dies in first 5 seconds total (2s above + 1s here)
sleep 1
if ! kill -0 "$AGENT_PID" 2>/dev/null; then
  wait "$AGENT_PID" 2>/dev/null
  EXIT_CODE=$?
  AGENT_PID=""
  END=$(date +%s)
  DURATION=$((END - START))
  COST=$(jq -r '.total_cost_usd // .cost_usd // 0' "$TRANSCRIPT" 2>/dev/null || echo 0)
  DETAIL=$(head -c 200 "$TRANSCRIPT" 2>/dev/null | tr '\n' ' ' || echo "agent died immediately")
  emit_final "failed" ",\"detail\":\"agent died in <3s (auth? crash?): $(echo "$DETAIL" | jq -Rs '.'| head -c 150)\",\"cost_usd\":${COST},\"duration_s\":${DURATION}"
  echo "Agent died immediately. Transcript: $TRANSCRIPT"
  exit 1
fi
while kill -0 "$AGENT_PID" 2>/dev/null; do
  sleep 5
  ELAPSED=$(( $(date +%s) - START ))
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

wait "$AGENT_PID" 2>/dev/null
EXIT_CODE=$?
AGENT_PID=""  # Clear so cleanup doesn't try to kill again

END=$(date +%s)
DURATION=$((END - START))

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
# These should count as "failed" so the heartbeat backoff kicks in.
# Catches: guardrail blocks, "no work available", claimed tasks, etc.
UNPRODUCTIVE=false
UNPRODUCTIVE_REASON=""
if [ "$DURATION" -lt 120 ] && [ $EXIT_CODE -eq 0 ]; then
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
    if [ "$GB_COUNT" -gt 0 ]; then
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
elif [ "$UNPRODUCTIVE" = true ]; then
  emit_final "failed" ",\"detail\":\"unproductive run (${UNPRODUCTIVE_REASON})\",\"cost_usd\":${COST},\"duration_s\":${DURATION},\"turns\":${TURNS}"
else
  emit_final "done" ",\"cost_usd\":${COST},\"duration_s\":${DURATION},\"turns\":${TURNS},\"exit_reason\":${EXIT_REASON}"
fi

# Auto-label new PRs with awaiting:verifier (state machine entry point).
# Only labels PRs that have no awaiting: or verified label yet.
if [ "$TYPE" != "pr-verifier" ] && [ "$TYPE" != "pr-responder" ]; then
  for pr_num in $(gh pr list --repo skwallace36/Pepper-private --state open --author "pepper-${TYPE}-agent" \
    --json number,labels --jq '.[] | select(.labels | map(.name) | (index("awaiting:verifier") | not) and (index("awaiting:responder") | not) and (index("awaiting:human") | not) and (index("verified") | not)) | .number' 2>/dev/null); do
    "$REPO_ROOT/scripts/classify-pr.sh" "$pr_num" 2>/dev/null || true
  done
fi

# Auto-chain: if this agent opened a PR, launch the verifier next.
# Only chains if heartbeat is alive (prevents zombie chains after kill).
if [ "$TYPE" != "pr-verifier" ] && [ "$TYPE" != "pr-responder" ]; then
  HB_PID=$(cat "$REPO_ROOT/build/logs/heartbeat.pid" 2>/dev/null)
  if [ -n "$HB_PID" ] && kill -0 "$HB_PID" 2>/dev/null; then
    VERIFIER_LOCK="build/logs/.lock-pr-verifier"
    VERIFIER_RUNNING=false
    for lf in ${VERIFIER_LOCK}-*; do
      [ -f "$lf" ] && kill -0 "$(cat "$lf" 2>/dev/null)" 2>/dev/null && VERIFIER_RUNNING=true && break
    done
    if [ "$VERIFIER_RUNNING" = false ]; then
      AWAITING_VERIFY=$(gh pr list --repo skwallace36/Pepper-private --state open --label "awaiting:verifier" \
        --json number --jq 'length' 2>/dev/null || echo 0)
      if [ "$AWAITING_VERIFY" -gt 0 ]; then
        echo "$AWAITING_VERIFY PR(s) awaiting verification — chaining pr-verifier..."
        nohup "$REPO_ROOT/scripts/agent-runner.sh" pr-verifier >> build/logs/chain.log 2>&1 &
      fi
    fi
  fi
fi

echo "Done. Transcript: $TRANSCRIPT"

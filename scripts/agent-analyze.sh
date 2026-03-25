#!/bin/bash
# scripts/agent-analyze.sh — post-hoc analysis of agent sessions
# Usage:
#   ./scripts/agent-analyze.sh                    # analyze all sessions
#   ./scripts/agent-analyze.sh --last N           # analyze last N sessions
#   ./scripts/agent-analyze.sh --type bugfix      # filter by agent type
#   ./scripts/agent-analyze.sh --session TS       # analyze a specific session (by start timestamp)

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EVENTS="$REPO_ROOT/build/logs/events.jsonl"

LAST=""
FILTER_TYPE=""
FILTER_SESSION=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --last)  LAST="$2"; shift 2 ;;
    --type)  FILTER_TYPE="$2"; shift 2 ;;
    --session) FILTER_SESSION="$2"; shift 2 ;;
    *)       echo "Unknown: $1"; exit 1 ;;
  esac
done

if [ ! -f "$EVENTS" ]; then
  echo "No events file: $EVENTS"
  exit 1
fi

# All analysis done in a single python pass for speed
python3 - "$EVENTS" "$LAST" "$FILTER_TYPE" "$FILTER_SESSION" <<'PYEOF'
import json, sys, os, re, subprocess
from collections import defaultdict
from datetime import datetime

events_file = sys.argv[1]
last_n = int(sys.argv[2]) if sys.argv[2] else 0
filter_type = sys.argv[3] or None
filter_session = sys.argv[4] or None

# Parse all events
events = []
with open(events_file) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            events.append(json.loads(line))
        except json.JSONDecodeError:
            continue

# Group events into sessions (started → done/failed/timeout/killed)
sessions = []
open_sessions = {}  # agent -> session

for e in events:
    agent = e.get("agent", "?")
    event = e.get("event", "")
    ts = e.get("ts", "")

    if event == "started":
        open_sessions[agent] = {
            "agent": agent,
            "start": ts,
            "events": [e],
            "end": None,
            "outcome": None,
            "cost": 0,
            "duration": 0,
            "prs": [],
            "issue": None,
            "crashes": [],
        }
    elif event in ("done", "failed", "timeout", "killed"):
        if agent in open_sessions:
            sess = open_sessions.pop(agent)
            sess["events"].append(e)
            sess["end"] = ts
            sess["outcome"] = event
            sess["cost"] = e.get("cost_usd", 0)
            sess["duration"] = e.get("duration_s", 0)
            sessions.append(sess)
        else:
            # Orphan end event — create a minimal session
            sessions.append({
                "agent": agent,
                "start": ts,
                "events": [e],
                "end": ts,
                "outcome": event,
                "cost": e.get("cost_usd", 0),
                "duration": e.get("duration_s", 0),
                "prs": [],
                "issue": None,
            })
    elif event == "crash":
        if agent in open_sessions:
            open_sessions[agent]["events"].append(e)
            open_sessions[agent]["crashes"].append({
                "exc_type": e.get("exc_type", "?"),
                "signal": e.get("signal", "?"),
                "origin": e.get("origin", "?"),
                "dedupe_key": e.get("dedupe_key", "?"),
                "detail": e.get("detail", "?"),
            })
    elif event == "pr":
        if agent in open_sessions:
            open_sessions[agent]["events"].append(e)
            url = e.get("url", "")
            if url:
                open_sessions[agent]["prs"].append(url)
    elif event == "branch":
        if agent in open_sessions:
            open_sessions[agent]["events"].append(e)
            detail = e.get("detail", "")
            m = re.search(r'(?:TASK|BUG|ISSUE)-(\d+)', detail, re.IGNORECASE)
            if not m:
                m = re.search(r'/(\d+)$', detail)
            if m:
                open_sessions[agent]["issue"] = m.group(1)
    else:
        if agent in open_sessions:
            open_sessions[agent]["events"].append(e)

# Apply filters
if filter_type:
    sessions = [s for s in sessions if s["agent"] == filter_type]
if filter_session:
    sessions = [s for s in sessions if s["start"].startswith(filter_session)]
if last_n:
    sessions = sessions[-last_n:]

if not sessions:
    print("No sessions found.")
    sys.exit(0)

# ANSI
BOLD = "\033[1m"
DIM = "\033[2m"
RED = "\033[31m"
GREEN = "\033[32m"
YELLOW = "\033[33m"
CYAN = "\033[36m"
NC = "\033[0m"

def fmt_bytes(b):
    if b >= 1_000_000:
        return f"{b/1_000_000:.1f}MB"
    if b >= 1_000:
        return f"{b/1_000:.1f}KB"
    return f"{b}B"

def fmt_dur(s):
    try:
        s = int(float(s))
    except (ValueError, TypeError):
        return "?s"
    if s >= 60:
        return f"{s//60}m {s%60}s"
    return f"{s}s"

def outcome_color(o):
    return {"done": GREEN, "failed": RED, "timeout": RED, "killed": YELLOW}.get(o, "")

# Per-session analysis
print(f"\n{BOLD}{'='*70}")
print(f"  pepper agent session analysis")
print(f"{'='*70}{NC}\n")

total_bytes_all = 0
total_reads_all = 0
total_rereads_all = 0

for i, sess in enumerate(sessions):
    agent = sess["agent"]
    outcome = sess["outcome"] or "?"
    cost = sess["cost"]
    duration = sess["duration"]
    oc = outcome_color(outcome)

    print(f"{BOLD}Session {i+1}: {agent}{NC}  {DIM}{sess['start']} → {sess['end'] or '?'}{NC}")
    print(f"  Outcome: {oc}{outcome.upper()}{NC}  Cost: ${cost}  Duration: {fmt_dur(duration)}")

    # Tally by event type
    by_type = defaultdict(lambda: {"count": 0, "bytes": 0})
    files_read = defaultdict(lambda: {"count": 0, "bytes": 0})
    files_written = []
    files_edited = []

    for e in sess["events"]:
        ev = e.get("event", "")
        b = 0
        try:
            b = int(e.get("bytes", 0))
        except (ValueError, TypeError):
            pass

        if ev in ("read", "edit", "write", "grep", "glob", "pepper", "gh", "build", "build-fail"):
            by_type[ev]["count"] += 1
            by_type[ev]["bytes"] += b

        if ev == "read":
            f = e.get("file", "?")
            files_read[f]["count"] += 1
            files_read[f]["bytes"] += b

        if ev == "edit":
            files_edited.append(e.get("file", "?"))
        if ev == "write":
            files_written.append(e.get("file", "?"))

    # Context breakdown
    total_bytes = sum(v["bytes"] for v in by_type.values())
    total_bytes_all += total_bytes

    if by_type:
        print(f"\n  {BOLD}Context consumed: {fmt_bytes(total_bytes)}{NC}")
        for ev_name in ["read", "grep", "glob", "pepper", "gh", "build", "edit", "write"]:
            if ev_name in by_type:
                t = by_type[ev_name]
                pct = (t["bytes"] / total_bytes * 100) if total_bytes > 0 else 0
                bar = "█" * int(pct / 5)
                print(f"    {ev_name:<10} {t['count']:>3}x  {fmt_bytes(t['bytes']):>8}  {DIM}{bar}{NC} {pct:.0f}%")

    # Re-reads
    rereads = {f: v for f, v in files_read.items() if v["count"] > 1}
    total_reads = sum(v["count"] for v in files_read.values())
    total_rereads = sum(v["count"] - 1 for v in rereads.values())
    total_reads_all += total_reads
    total_rereads_all += total_rereads

    if rereads:
        wasted = sum((v["count"] - 1) * v["bytes"] // v["count"] for v in rereads.values())
        print(f"\n  {YELLOW}Re-reads: {total_rereads} ({fmt_bytes(wasted)} wasted){NC}")
        for f, v in sorted(rereads.items(), key=lambda x: x[1]["count"], reverse=True)[:5]:
            short = os.path.basename(f)
            print(f"    {short:<40} {v['count']}x  ({fmt_bytes(v['bytes'])} total)")
    elif total_reads > 0:
        print(f"\n  {GREEN}No re-reads ({total_reads} unique file reads){NC}")

    # Crashes
    crashes = sess.get("crashes", [])
    if crashes:
        print(f"\n  {RED}Crashes: {len(crashes)}{NC}")
        seen_keys = set()
        for c in crashes:
            dk = c["dedupe_key"]
            dupe = " (repeat)" if dk in seen_keys else ""
            seen_keys.add(dk)
            origin_tag = f" [{c['origin'].upper()}]" if c.get("origin") else ""
            print(f"    {c['exc_type']} ({c['signal']}){origin_tag}{dupe}")
            print(f"      {DIM}{c['detail']}{NC}")

    # Top files by bytes
    if files_read:
        top = sorted(files_read.items(), key=lambda x: x[1]["bytes"], reverse=True)[:5]
        print(f"\n  Top files by size:")
        for f, v in top:
            short = f.replace(os.path.expanduser("~"), "~")
            # Trim long worktree paths
            if "/.claude/worktrees/" in short:
                short = short.split("/.claude/worktrees/")[1]
                short = "/".join(short.split("/")[1:])  # drop worktree name
            print(f"    {short:<50} {fmt_bytes(v['bytes'])}")

    print()

# Summary across all sessions
if len(sessions) > 1:
    print(f"{BOLD}{'─'*70}")
    print(f"  Summary ({len(sessions)} sessions){NC}")
    print(f"  Total context: {fmt_bytes(total_bytes_all)}")
    print(f"  Total reads: {total_reads_all}  Re-reads: {total_rereads_all}", end="")
    if total_reads_all > 0:
        print(f" ({total_rereads_all/total_reads_all*100:.0f}% waste)")
    else:
        print()

    # Crash summary across all sessions
    all_crashes = []
    for sess in sessions:
        all_crashes.extend(sess.get("crashes", []))
    if all_crashes:
        crash_by_key = defaultdict(lambda: {"count": 0, "detail": "", "origin": ""})
        for c in all_crashes:
            entry = crash_by_key[c["dedupe_key"]]
            entry["count"] += 1
            entry["detail"] = c["detail"]
            entry["origin"] = c.get("origin", "?")
        print(f"\n  {RED}Crashes: {len(all_crashes)} total, {len(crash_by_key)} unique signatures{NC}")
        for dk, info in sorted(crash_by_key.items(), key=lambda x: x[1]["count"], reverse=True):
            origin_tag = f" [{info['origin'].upper()}]" if info.get("origin") else ""
            print(f"    {info['count']}x{origin_tag} {info['detail'][:80]}")

    # Per-type summary
    type_stats = defaultdict(lambda: {"count": 0, "bytes": 0, "cost": 0, "duration": 0})
    for sess in sessions:
        t = type_stats[sess["agent"]]
        t["count"] += 1
        t["bytes"] += sum(
            int(e.get("bytes", 0))
            for e in sess["events"]
            if e.get("event") in ("read", "grep", "glob", "pepper", "gh", "build")
        )
        try:
            t["cost"] += float(sess["cost"])
        except (ValueError, TypeError):
            pass
        try:
            t["duration"] += int(float(sess["duration"]))
        except (ValueError, TypeError):
            pass

    print(f"\n  {'Agent':<15} {'Runs':>5} {'Bytes':>10} {'Avg Bytes':>10} {'Cost':>8} {'Avg Dur':>8}")
    print(f"  {'─'*58}")
    for agent, t in sorted(type_stats.items()):
        avg_bytes = t["bytes"] // t["count"] if t["count"] else 0
        avg_dur = t["duration"] // t["count"] if t["count"] else 0
        print(f"  {agent:<15} {t['count']:>5} {fmt_bytes(t['bytes']):>10} {fmt_bytes(avg_bytes):>10} ${t['cost']:>6.2f} {fmt_dur(avg_dur):>8}")

    # ── Efficiency metrics ──────────────────────────────────────────
    # Collect per-type: successes (done outcomes), PRs opened, costs
    eff = defaultdict(lambda: {
        "total": 0, "done": 0, "failed": 0,
        "cost": 0.0, "pr_urls": [], "issues": defaultdict(int),
    })
    for sess in sessions:
        a = sess["agent"]
        eff[a]["total"] += 1
        if sess["outcome"] == "done":
            eff[a]["done"] += 1
        elif sess["outcome"] in ("failed", "timeout"):
            eff[a]["failed"] += 1
        try:
            eff[a]["cost"] += float(sess["cost"])
        except (ValueError, TypeError):
            pass
        eff[a]["pr_urls"].extend(sess.get("prs", []))
        issue = sess.get("issue")
        if issue:
            eff[a]["issues"][issue] += 1

    # Check which PRs are merged (batch gh calls)
    all_pr_urls = set()
    for t in eff.values():
        all_pr_urls.update(t["pr_urls"])
    merged_urls = set()
    for url in all_pr_urls:
        try:
            result = subprocess.run(
                ["gh", "pr", "view", url, "--json", "state", "-q", ".state"],
                capture_output=True, text=True, timeout=10,
            )
            if result.returncode == 0 and result.stdout.strip() == "MERGED":
                merged_urls.add(url)
        except (subprocess.TimeoutExpired, FileNotFoundError):
            pass

    print(f"\n{BOLD}{'─'*70}")
    print(f"  Efficiency Metrics{NC}")

    hdr = f"  {'Agent':<15} {'Success%':>8} {'PRs':>5} {'Merged':>7} {'$/PR':>8} {'$/Merged':>9} {'Avg Att':>8}"
    print(hdr)
    print(f"  {'─'*62}")
    for agent, e in sorted(eff.items()):
        total = e["total"]
        done = e["done"]
        rate = (done / total * 100) if total else 0
        prs = len(e["pr_urls"])
        merged = sum(1 for u in e["pr_urls"] if u in merged_urls)
        cost = e["cost"]
        cost_pr = f"${cost / prs:.2f}" if prs else "—"
        cost_merged = f"${cost / merged:.2f}" if merged else "—"
        # Avg attempts: mean sessions per issue for issues with >0 sessions
        issues = e["issues"]
        avg_att = f"{sum(issues.values()) / len(issues):.1f}" if issues else "—"

        rc = GREEN if rate >= 70 else (YELLOW if rate >= 40 else RED)
        print(f"  {agent:<15} {rc}{rate:>7.0f}%{NC} {prs:>5} {merged:>7} {cost_pr:>8} {cost_merged:>9} {avg_att:>8}")

    print()
PYEOF

#!/usr/bin/env python3
"""scripts/agent-dashboard.py — Textual TUI dashboard for Pepper agent monitoring.

Replaces agent-monitor.sh with a real TUI: sticky header, scrollable event stream,
noise suppression, keyboard shortcuts. Reads build/logs/events.jsonl.

Usage:
    python3 scripts/agent-dashboard.py
    make dashboard
"""

from __future__ import annotations

import json
import os
import signal
import sys
import time
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

try:
    from textual.app import App, ComposeResult
    from textual.binding import Binding
    from textual.containers import Horizontal, Vertical
    from textual.reactive import reactive
    from textual.widget import Widget
    from textual.widgets import Footer, RichLog, Static
except ImportError:
    print("textual not installed. Install with: pip install textual")
    print("Falling back to agent-monitor.sh...")
    repo = Path(__file__).resolve().parent.parent
    os.execvp("bash", ["bash", str(repo / "scripts" / "agent-monitor.sh")])

from rich.text import Text

# ─── Constants ────────────────────────────────────────────────────────

REPO_ROOT = Path(__file__).resolve().parent.parent
EVENTS_PATH = REPO_ROOT / "build" / "logs" / "events.jsonl"
KILL_SWITCH = REPO_ROOT / ".pepper-kill"
HEARTBEAT_PID = REPO_ROOT / "build" / "logs" / "heartbeat.pid"

AGENT_COLORS: dict[str, str] = {
    "bugfix": "red",
    "builder": "magenta",
    "tester": "cyan",
    "pr-responder": "yellow",
    "pr-verifier": "green",
    "verifier": "green",
    "researcher": "blue",
    "groomer": "white",
    "conflict-resolver": "cyan",
}

AGENT_ICONS: dict[str, str] = {
    "bugfix": "B",
    "builder": "W",
    "tester": "T",
    "pr-responder": "R",
    "pr-verifier": "V",
    "verifier": "V",
    "researcher": "?",
    "groomer": "G",
    "conflict-resolver": "C",
}

# Events that represent lifecycle milestones (not tool noise)
LIFECYCLE_EVENTS = {
    "started", "branch", "commit", "push", "pr", "done",
    "failed", "timeout", "killed", "build", "build-fail",
    "guardrail-block", "task-claimed",
}

# Tool-level events (dimmed / suppressible)
TOOL_EVENTS = {"read", "edit", "write", "grep", "glob", "gh", "pepper", "pepper-fail"}

LOCAL_TZ = datetime.now().astimezone().tzinfo


# ─── Helpers ──────────────────────────────────────────────────────────

def parse_event(line: str) -> dict[str, Any] | None:
    line = line.strip()
    if not line:
        return None
    try:
        return json.loads(line)
    except (json.JSONDecodeError, ValueError):
        return None


def load_events(path: Path) -> list[dict[str, Any]]:
    if not path.exists():
        return []
    events = []
    with open(path) as f:
        for line in f:
            ev = parse_event(line)
            if ev:
                events.append(ev)
    return events


def fmt_ts(ts_str: str) -> str:
    """Convert UTC ISO timestamp to local HH:MM:SS am/pm."""
    try:
        dt = datetime.fromisoformat(ts_str.replace("Z", "+00:00"))
        local = dt.astimezone(LOCAL_TZ)
        return local.strftime("%I:%M:%S%p").lower().lstrip("0")
    except (ValueError, AttributeError):
        return ts_str[11:19] if len(ts_str) > 19 else ts_str


def fmt_duration(seconds: int | float | None) -> str:
    if seconds is None:
        return ""
    s = int(seconds)
    if s >= 60:
        return f"{s // 60}m {s % 60}s"
    return f"{s}s"


def fmt_cost(cost: float | None) -> str:
    if cost is None:
        return ""
    return f"${cost:.2f}"


def fmt_bytes(b: int) -> str:
    if b >= 1_000_000:
        return f"{b / 1_000_000:.1f}MB"
    if b >= 1_000:
        return f"{b / 1_000:.1f}KB"
    return f"{b}B"


def is_heartbeat_running() -> tuple[bool, int | None]:
    if not HEARTBEAT_PID.exists():
        return False, None
    try:
        pid = int(HEARTBEAT_PID.read_text().strip())
        os.kill(pid, 0)
        return True, pid
    except (ValueError, ProcessLookupError, PermissionError, OSError):
        return False, None


def is_kill_switch_active() -> bool:
    return KILL_SWITCH.exists()


def get_active_agents() -> list[tuple[str, int]]:
    """Return list of (agent_type, pid) for running agents."""
    locks_dir = REPO_ROOT / "build" / "logs"
    agents = []
    if not locks_dir.exists():
        return agents
    for lock in locks_dir.glob(".lock-*"):
        try:
            pid = int(lock.read_text().strip())
            # Extract agent type from .lock-<type>-<n> or .lock-<type>
            name = lock.name.removeprefix(".lock-")
            # Strip trailing -N suffix (instance number)
            parts = name.rsplit("-", 1)
            if len(parts) == 2 and parts[1].isdigit():
                name = parts[0]
            os.kill(pid, 0)  # Check if alive
            agents.append((name, pid))
        except (ValueError, ProcessLookupError, PermissionError, OSError):
            continue
    return agents


def compute_stats(events: list[dict[str, Any]]) -> dict[str, Any]:
    """Compute today's and all-time stats from events."""
    today = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    today_events = [e for e in events if e.get("ts", "").startswith(today)]

    final_events = {"done", "failed", "timeout", "killed"}

    return {
        "today_runs": len([e for e in today_events if e.get("event") == "started"]),
        "today_ok": len([e for e in today_events if e.get("event") == "done"]),
        "today_fail": len([e for e in today_events if e.get("event") in ("failed", "timeout")]),
        "today_commits": len([e for e in today_events if e.get("event") == "commit"]),
        "today_prs": len([e for e in today_events if e.get("event") == "pr"]),
        "today_cost": sum(float(e.get("cost_usd", 0)) for e in today_events if e.get("event") in final_events),
        "all_runs": len([e for e in events if e.get("event") == "started"]),
        "all_prs": len([e for e in events if e.get("event") == "pr"]),
        "all_cost": sum(float(e.get("cost_usd", 0)) for e in events if e.get("event") in final_events),
    }


# ─── Event formatting ────────────────────────────────────────────────

EVENT_STYLES: dict[str, str] = {
    "started": "bold blue",
    "branch": "cyan",
    "commit": "yellow",
    "push": "magenta",
    "pr": "bold green",
    "done": "bold green",
    "failed": "bold red",
    "timeout": "bold red",
    "killed": "bold red",
    "build": "green",
    "build-fail": "bold red",
    "guardrail-block": "bold red",
    "task-claimed": "bold cyan",
}


def format_event(ev: dict[str, Any], show_tools: bool = True) -> Text | None:
    """Format a single event as a Rich Text object. Returns None to suppress."""
    event = ev.get("event", "?")
    agent = ev.get("agent", "?")
    detail = ev.get("detail", "")
    ts = fmt_ts(ev.get("ts", ""))
    agent_color = AGENT_COLORS.get(agent, "white")
    icon = AGENT_ICONS.get(agent, " ")

    # Suppress session-summary in display
    if event == "session-summary":
        return None

    # Tool events — dim or skip
    if event in TOOL_EVENTS:
        if not show_tools:
            return None
        file_val = ev.get("file", "")
        extra = os.path.basename(file_val) if file_val else detail
        byt = ev.get("bytes", 0)
        if byt:
            extra = f"{extra} ({fmt_bytes(int(byt))})" if extra else fmt_bytes(int(byt))
        text = Text()
        text.append(f"{ts:>11}  ", style="dim")
        text.append(f"[{icon}]", style=f"dim {agent_color}")
        text.append(f" {agent:<12} ", style="dim")
        text.append(f"{event:<9} ", style="dim")
        text.append(extra or "", style="dim")
        return text

    # Noise suppression: capacity checks, unproductive runs → dim
    if event == "failed" and detail and ("at capacity" in detail or "unproductive run" in detail):
        text = Text()
        text.append(f"{ts:>11}  ", style="dim")
        text.append(f"[{icon}]", style=f"dim {agent_color}")
        text.append(f" {agent:<12} ", style="dim")
        text.append("skipped  ", style="dim")
        text.append(detail, style="dim")
        return text

    # Kill switch collapse — caller tracks this
    event_style = EVENT_STYLES.get(event, "")
    label = event.upper().replace("-", " ")
    if event == "build-fail":
        label = "BUILD X"

    text = Text()
    text.append(f"{ts:>11}  ")
    text.append(f"[{icon}]", style=agent_color)
    text.append(f" {agent:<12} ")
    text.append(f"{label:<9} ", style=event_style)

    # Event-specific detail
    if event == "done":
        cost = ev.get("cost_usd")
        dur = ev.get("duration_s")
        turns = ev.get("turns")
        exit_reason = ev.get("exit_reason", "")
        parts = []
        if cost is not None:
            parts.append(fmt_cost(float(cost)))
        if dur is not None:
            parts.append(fmt_duration(dur))
        if turns:
            parts.append(f"{turns}t")
        if exit_reason and len(str(exit_reason)) < 80:
            parts.append(str(exit_reason))
        text.append(" · ".join(parts))
    elif event == "pr":
        url = ev.get("url", "")
        text.append(f"{detail} {url}")
    elif event == "guardrail-block":
        tool = ev.get("tool", "")
        text.append(f"[{tool}] {detail}")
    else:
        text.append(detail or "")
        if event in ("failed", "timeout"):
            cost = ev.get("cost_usd")
            dur = ev.get("duration_s")
            extras = []
            if cost and float(cost) > 0:
                extras.append(fmt_cost(float(cost)))
            if dur:
                extras.append(fmt_duration(dur))
            if extras:
                text.append(f" · {' · '.join(extras)}")

    return text


# ─── Textual Widgets ─────────────────────────────────────────────────

class StatsHeader(Static):
    """Sticky header showing heartbeat, agents, and stats."""

    def render_stats(self) -> Text:
        text = Text()

        # Heartbeat
        running, pid = is_heartbeat_running()
        if running:
            text.append(" ● ", style="bold green")
            text.append(f"heartbeat running (PID {pid})  ", style="green")
        else:
            text.append(" ○ ", style="dim")
            text.append("heartbeat not running  ", style="dim")

        # Kill switch
        if is_kill_switch_active():
            text.append("Kill: ", style="dim")
            text.append("● ACTIVE", style="bold red")
        else:
            text.append("Kill: ", style="dim")
            text.append("○ inactive", style="dim")

        text.append("\n")

        # Active agents
        agents = get_active_agents()
        if agents:
            text.append(" Agents: ")
            for i, (atype, _pid) in enumerate(agents):
                color = AGENT_COLORS.get(atype, "white")
                icon = AGENT_ICONS.get(atype, " ")
                if i > 0:
                    text.append("  ")
                text.append(f"[{icon}]", style=f"bold {color}")
                text.append(f" {atype}", style=color)
        else:
            text.append(" Agents: ", style="dim")
            text.append("none running", style="dim")

        text.append("\n")

        # Stats
        events = load_events(EVENTS_PATH)
        stats = compute_stats(events)

        text.append(f" Today: {stats['today_runs']} runs")
        if stats["today_ok"] or stats["today_fail"]:
            text.append(f" ({stats['today_ok']} ok, {stats['today_fail']} fail)")
        text.append(f" · {stats['today_commits']} commits")
        text.append(f" · {stats['today_prs']} PRs")
        text.append(f" · ${stats['today_cost']:.2f}")
        text.append("\n")

        text.append(f" All-time: {stats['all_runs']} runs · {stats['all_prs']} PRs · ${stats['all_cost']:.2f}", style="dim")

        return text

    def render(self) -> Text:
        return self.render_stats()


class EventStream(RichLog):
    """Scrollable event log that auto-scrolls and supports pause."""
    pass


class PRSummary(Static):
    """Bottom bar showing PR queue summary."""

    def render_pr_summary(self) -> Text:
        text = Text()
        events = load_events(EVENTS_PATH)
        today = datetime.now(timezone.utc).strftime("%Y-%m-%d")
        today_prs = [e for e in events if e.get("event") == "pr" and e.get("ts", "").startswith(today)]

        if today_prs:
            text.append(f" PRs opened today: {len(today_prs)}", style="bold")
            # Show last 3 PR details
            for pr_ev in today_prs[-3:]:
                agent = pr_ev.get("agent", "?")
                detail = pr_ev.get("detail", "")
                color = AGENT_COLORS.get(agent, "white")
                text.append(f"  ")
                text.append(f"{agent}", style=color)
                text.append(f" {detail}")
        else:
            text.append(" No PRs today", style="dim")

        return text

    def render(self) -> Text:
        return self.render_pr_summary()


# ─── Main App ────────────────────────────────────────────────────────

DASHBOARD_CSS = """
Screen {
    layout: vertical;
}

#header-box {
    height: auto;
    max-height: 7;
    border-bottom: solid $accent;
    padding: 0;
}

#event-stream {
    height: 1fr;
}

#pr-summary {
    height: 2;
    border-top: solid $accent;
    padding: 0;
}

Footer {
    height: 1;
}
"""


class AgentDashboard(App):
    """Pepper Agent Dashboard — TUI for monitoring agent events."""

    TITLE = "Pepper Agent Dashboard"
    CSS = DASHBOARD_CSS

    BINDINGS = [
        Binding("q", "quit", "Quit"),
        Binding("p", "toggle_pause", "Pause"),
        Binding("t", "toggle_tools", "Tools"),
        Binding("k", "toggle_kill", "Kill Switch"),
        Binding("r", "refresh_stats", "Refresh"),
    ]

    paused: reactive[bool] = reactive(False)
    show_tools: reactive[bool] = reactive(False)

    def __init__(self) -> None:
        super().__init__()
        self._file_pos: int = 0
        self._kill_count: int = 0
        self._last_kill_agent: str = ""

    def compose(self) -> ComposeResult:
        yield StatsHeader(id="header-box")
        yield EventStream(id="event-stream", highlight=True, markup=False, auto_scroll=True)
        yield PRSummary(id="pr-summary")
        yield Footer()

    def on_mount(self) -> None:
        # Load existing events
        self._load_history()
        # Poll for new events every 1 second
        self.set_interval(1.0, self._poll_events)
        # Refresh header/footer every 15 seconds
        self.set_interval(15.0, self._refresh_widgets)

    def _load_history(self) -> None:
        """Load recent lifecycle events from history."""
        if not EVENTS_PATH.exists():
            return
        stream = self.query_one("#event-stream", EventStream)
        events = load_events(EVENTS_PATH)

        # Show last 200 lifecycle events for context
        lifecycle = [e for e in events if e.get("event") in LIFECYCLE_EVENTS]
        recent = lifecycle[-200:]

        for ev in recent:
            formatted = format_event(ev, show_tools=False)
            if formatted:
                stream.write(formatted)

        # Set file position to end
        try:
            self._file_pos = EVENTS_PATH.stat().st_size
        except OSError:
            self._file_pos = 0

    def _poll_events(self) -> None:
        """Check for new events appended to the log file."""
        if self.paused:
            return
        if not EVENTS_PATH.exists():
            return

        try:
            size = EVENTS_PATH.stat().st_size
        except OSError:
            return

        if size <= self._file_pos:
            # File may have been rotated
            if size < self._file_pos:
                self._file_pos = 0
            else:
                return

        stream = self.query_one("#event-stream", EventStream)

        with open(EVENTS_PATH) as f:
            f.seek(self._file_pos)
            new_data = f.read()
            self._file_pos = f.tell()

        for line in new_data.splitlines():
            ev = parse_event(line)
            if not ev:
                continue

            event_type = ev.get("event", "")
            agent = ev.get("agent", "")
            detail = ev.get("detail", "")

            # Kill switch collapse
            if event_type == "killed" and "kill switch" in str(detail):
                if agent == self._last_kill_agent:
                    self._kill_count += 1
                    if self._kill_count > 1:
                        # Overwrite would be complex in RichLog; just dim it
                        text = Text()
                        text.append(f"  {'':>11}  ", style="dim")
                        icon = AGENT_ICONS.get(agent, " ")
                        text.append(f"[{icon}]", style=f"dim {AGENT_COLORS.get(agent, 'white')}")
                        text.append(f" {agent:<12} ", style="dim")
                        text.append(f"killed    (kill switch × {self._kill_count})", style="dim")
                        stream.write(text)
                        continue
                else:
                    self._kill_count = 1
                    self._last_kill_agent = agent
            else:
                if event_type != "killed":
                    self._kill_count = 0

            formatted = format_event(ev, show_tools=self.show_tools)
            if formatted:
                stream.write(formatted)

    def _refresh_widgets(self) -> None:
        """Refresh header and PR summary."""
        self.query_one("#header-box", StatsHeader).refresh()
        self.query_one("#pr-summary", PRSummary).refresh()

    def action_toggle_pause(self) -> None:
        self.paused = not self.paused
        stream = self.query_one("#event-stream", EventStream)
        stream.auto_scroll = not self.paused
        status = "PAUSED" if self.paused else "resumed"
        self.notify(f"Event stream {status}", timeout=2)

    def action_toggle_tools(self) -> None:
        self.show_tools = not self.show_tools
        status = "shown" if self.show_tools else "hidden"
        self.notify(f"Tool events {status}", timeout=2)

    def action_toggle_kill(self) -> None:
        if KILL_SWITCH.exists():
            KILL_SWITCH.unlink()
            self.notify("Kill switch DEACTIVATED", timeout=3)
        else:
            KILL_SWITCH.touch()
            self.notify("Kill switch ACTIVATED", severity="warning", timeout=3)
        self.query_one("#header-box", StatsHeader).refresh()

    def action_refresh_stats(self) -> None:
        self._refresh_widgets()
        self.notify("Stats refreshed", timeout=1)


def main() -> None:
    # Ensure log directory exists
    (REPO_ROOT / "build" / "logs").mkdir(parents=True, exist_ok=True)

    app = AgentDashboard()
    app.run()


if __name__ == "__main__":
    main()

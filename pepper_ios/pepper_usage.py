"""Tool usage logging — appends to ~/.pepper/tool_usage.jsonl on every MCP tool call."""

from __future__ import annotations

import json
import os
import time
import uuid

_SESSION_ID = uuid.uuid4().hex[:12]
_USAGE_DIR = os.path.join(os.path.expanduser("~"), ".pepper")
_USAGE_PATH = os.path.join(_USAGE_DIR, "tool_usage.jsonl")


def log_tool_call(tool_name: str) -> None:
    """Append one line to the usage log. Fire-and-forget, never raises."""
    try:
        os.makedirs(_USAGE_DIR, exist_ok=True)
        entry = json.dumps(
            {"tool": tool_name, "ts": time.strftime("%Y-%m-%dT%H:%M:%S"), "session": _SESSION_ID},
            separators=(",", ":"),
        )
        with open(_USAGE_PATH, "a") as f:
            f.write(entry + "\n")
    except Exception:
        pass  # Never block MCP on logging failures


def get_usage_summary(days: int = 30) -> dict:
    """Read the usage log and return tool counts for the last N days."""
    cutoff = time.time() - days * 86400
    counts: dict[str, int] = {}
    sessions: set[str] = set()
    total = 0
    try:
        with open(_USAGE_PATH) as f:
            for line in f:
                try:
                    entry = json.loads(line)
                    ts = time.mktime(time.strptime(entry["ts"], "%Y-%m-%dT%H:%M:%S"))
                    if ts >= cutoff:
                        tool = entry["tool"]
                        counts[tool] = counts.get(tool, 0) + 1
                        sessions.add(entry.get("session", ""))
                        total += 1
                except (json.JSONDecodeError, KeyError, ValueError):
                    continue
    except FileNotFoundError:
        pass
    return {
        "days": days,
        "total_calls": total,
        "sessions": len(sessions),
        "tools": dict(sorted(counts.items(), key=lambda x: -x[1])),
    }

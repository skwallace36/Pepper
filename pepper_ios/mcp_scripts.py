"""Script recording and replay engine for Pepper MCP.

Records sequences of action tool calls and replays them as single operations.
Scripts are stored as JSON in ~/.pepper/adapters/{type}/scripts/ or
~/.pepper/scripts/{bundle_id}/ for generic mode.
"""

from __future__ import annotations

import json
import os
import time
from datetime import datetime, timezone

from .pepper_common import ADAPTERS_DIR, get_config, resolve_adapter_dir

# Action tools that get recorded. Read-only tools (look, find, verify) are skipped.
RECORDABLE_TOOLS = frozenset({
    "tap", "scroll", "swipe", "input_text", "navigate", "back",
    "dismiss", "dismiss_keyboard", "gesture", "dialog", "toggle",
})

# Active recordings keyed by simulator UDID (or "default" for single-sim).
_recordings: dict[str, dict] = {}


def scripts_dir() -> str:
    """Resolve the scripts directory for the active app.

    Uses session context (set by deploy_sim) first, .env fallback.
    """
    from .mcp_build import get_session_context
    ctx = get_session_context()
    adapter_type = ctx.get("adapter_type") or get_config().get("adapter_type", "generic")
    adapter_dir = resolve_adapter_dir(adapter_type)
    if adapter_dir:
        return os.path.join(adapter_dir, "scripts")
    # Generic mode: store by bundle_id
    bundle_id = ctx.get("bundle_id") or get_config().get("bundle_id", "unknown")
    return os.path.join(os.path.expanduser("~"), ".pepper", "scripts", bundle_id)


def start_recording(name: str, description: str = "", sim_key: str = "default") -> str:
    """Start recording actions for the given simulator."""
    if sim_key in _recordings:
        return f"Already recording '{_recordings[sim_key]['name']}'. Stop it first with script action=stop."
    _recordings[sim_key] = {
        "name": name,
        "description": description,
        "steps": [],
        "start_time": time.monotonic(),
        "last_step_time": time.monotonic(),
    }
    return f"Recording '{name}'. Perform your actions, then call script action=stop."


def stop_recording(sim_key: str = "default") -> tuple[str, dict | None]:
    """Stop recording and save the script. Returns (message, script_dict)."""
    rec = _recordings.pop(sim_key, None)
    if not rec:
        return "No active recording.", None
    if not rec["steps"]:
        return f"Recording '{rec['name']}' had no steps. Nothing saved.", None

    config = get_config()
    script = {
        "name": rec["name"],
        "description": rec["description"],
        "bundle_id": config.get("bundle_id", ""),
        "created_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "steps": rec["steps"],
    }

    # Save to disk
    out_dir = scripts_dir()
    os.makedirs(out_dir, exist_ok=True)
    path = os.path.join(out_dir, f"{rec['name']}.json")
    with open(path, "w") as f:
        json.dump(script, f, indent=2)

    return f"Saved '{rec['name']}' ({len(rec['steps'])} steps) to {path}", script


def maybe_record_step(cmd: str, params: dict | None, sim_key: str = "default") -> None:
    """If recording is active, capture this action step."""
    if sim_key not in _recordings:
        return
    if cmd not in RECORDABLE_TOOLS:
        return
    rec = _recordings[sim_key]
    now = time.monotonic()
    wait_ms = int((now - rec["last_step_time"]) * 1000)
    rec["last_step_time"] = now

    step: dict = {"tool": cmd, "params": params or {}}
    if wait_ms > 100:  # Only record meaningful waits
        step["wait_ms"] = wait_ms
    rec["steps"].append(step)


def is_recording(sim_key: str = "default") -> bool:
    """Check if recording is active for this simulator."""
    return sim_key in _recordings


def list_scripts() -> list[dict]:
    """List available scripts for the current adapter."""
    sdir = scripts_dir()
    if not os.path.isdir(sdir):
        return []
    scripts = []
    for fname in sorted(os.listdir(sdir)):
        if not fname.endswith(".json"):
            continue
        path = os.path.join(sdir, fname)
        try:
            with open(path) as f:
                data = json.load(f)
            scripts.append({
                "name": data.get("name", fname[:-5]),
                "description": data.get("description", ""),
                "steps": len(data.get("steps", [])),
                "created_at": data.get("created_at", ""),
            })
        except (json.JSONDecodeError, OSError):
            continue
    return scripts


def load_script(name: str) -> dict | None:
    """Load a script by name."""
    sdir = scripts_dir()
    path = os.path.join(sdir, f"{name}.json")
    if not os.path.isfile(path):
        return None
    try:
        with open(path) as f:
            return json.load(f)
    except (json.JSONDecodeError, OSError):
        return None


def delete_script(name: str) -> str:
    """Delete a script by name."""
    sdir = scripts_dir()
    path = os.path.join(sdir, f"{name}.json")
    if not os.path.isfile(path):
        return f"Script '{name}' not found."
    os.remove(path)
    return f"Deleted '{name}'."

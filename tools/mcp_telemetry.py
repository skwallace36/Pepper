"""Telemetry snapshot, delta reporting, and act-and-look workflow for Pepper MCP."""

import asyncio
import json
from functools import partial
from typing import Any, Callable, Coroutine, Optional

from mcp_crash import fetch_crash_info
from pepper_common import discover_instance
from pepper_format import format_look

# Type alias for the send_command callable expected by these functions.
# Signature: async (port, cmd, params=None, timeout=10) -> dict
SendFn = Callable[..., Coroutine[Any, Any, dict]]


async def snapshot_counts(port: int, send_fn: SendFn) -> dict:
    """Snapshot network + console counts + memory before an action. Fast — just status queries."""
    # return_exceptions=True ensures gather never raises from inner tasks —
    # failed tasks are returned as exception objects handled by isinstance checks below.
    net_resp, console_resp, mem_resp = await asyncio.gather(
        send_fn(port, "network", {"action": "status"}, timeout=2),
        send_fn(port, "console", {"action": "status"}, timeout=2),
        send_fn(port, "memory", timeout=2),
        return_exceptions=True,
    )
    net_total = 0
    console_total = 0
    mem_mb = 0.0
    if isinstance(net_resp, dict) and net_resp.get("status") == "ok":
        net_total = net_resp.get("data", {}).get("total_recorded", 0)
    if isinstance(console_resp, dict) and console_resp.get("status") == "ok":
        console_total = console_resp.get("data", {}).get("total_captured", 0)
    if isinstance(mem_resp, dict) and mem_resp.get("status") == "ok":
        mem_mb = mem_resp.get("data", {}).get("resident_mb", 0.0)
    return {"net_total": net_total, "console_total": console_total, "mem_mb": mem_mb}


async def gather_telemetry(port: int, pre_counts: dict, send_fn: SendFn) -> str:
    """Gather ambient telemetry (network, console, idle state) and format as compact summary.
    Compares current counts against pre-action snapshot to show only new activity."""
    lines = []

    # Fire all telemetry queries concurrently
    net_task = asyncio.create_task(
        send_fn(port, "network", {"action": "log", "limit": 10}, timeout=2)
    )
    net_status_task = asyncio.create_task(
        send_fn(port, "network", {"action": "status"}, timeout=2)
    )
    console_task = asyncio.create_task(
        send_fn(port, "console", {"action": "log", "limit": 10}, timeout=2)
    )
    console_status_task = asyncio.create_task(
        send_fn(port, "console", {"action": "status"}, timeout=2)
    )
    idle_task = asyncio.create_task(
        send_fn(port, "wait_idle", {"debug": True}, timeout=2)
    )
    mem_task = asyncio.create_task(
        send_fn(port, "memory", timeout=2)
    )

    net_resp, net_status, console_resp, console_status, idle_resp, mem_resp = await asyncio.gather(
        net_task, net_status_task, console_task, console_status_task, idle_task, mem_task,
        return_exceptions=True,
    )

    # Network requests that fired during the action
    if isinstance(net_status, dict) and net_status.get("status") == "ok":
        new_count = net_status.get("data", {}).get("total_recorded", 0) - pre_counts.get("net_total", 0)
        if new_count > 0 and isinstance(net_resp, dict) and net_resp.get("status") == "ok":
            txns = net_resp.get("data", {}).get("transactions", [])
            # Take only the newest N that appeared during the action
            txns = txns[-new_count:] if new_count <= len(txns) else txns
            if txns:
                lines.append(f"network: {len(txns)} request(s)")
                for t in txns[:5]:
                    req = t.get("request", {})
                    resp = t.get("response", {})
                    timing = t.get("timing", {})
                    method = req.get("method", "?")
                    url = req.get("url", "")
                    status_code = resp.get("status_code", "...")
                    duration = timing.get("duration_ms", "")
                    # Compact URL: just path
                    path = url.split("//", 1)[-1].split("/", 1)[-1] if "//" in url else url
                    if len(path) > 60:
                        path = path[:57] + "..."
                    dur_str = f" {duration}ms" if duration else ""
                    lines.append(f"  {method} /{path} \u2192 {status_code}{dur_str}")
                if len(txns) > 5:
                    lines.append(f"  ... +{len(txns) - 5} more")

    # Duplicate request warnings (from network interceptor)
    if isinstance(net_status, dict) and net_status.get("status") == "ok":
        dupes = net_status.get("data", {}).get("duplicate_warnings", [])
        for d in dupes:
            if d.get("seconds_ago", 999) < 10:  # Only show recent duplicates
                endpoint = d.get("endpoint", "?")
                count = d.get("count", 0)
                window = d.get("window_ms", 0)
                lines.append(f"\u26a0 overfiring: {endpoint} called {count}x in {window}ms")

    # Console output during the action
    if isinstance(console_status, dict) and console_status.get("status") == "ok":
        new_count = console_status.get("data", {}).get("total_captured", 0) - pre_counts.get("console_total", 0)
        if new_count > 0 and isinstance(console_resp, dict) and console_resp.get("status") == "ok":
            entries = console_resp.get("data", {}).get("lines", [])
            entries = entries[-new_count:] if new_count <= len(entries) else entries
            if entries:
                lines.append(f"console: {len(entries)} line(s)")
                for e in entries[:3]:
                    msg = (e.get("message", "") if isinstance(e, dict) else str(e)).strip()
                    if msg:
                        disp = msg if len(msg) <= 80 else msg[:77] + "..."
                        lines.append(f"  {disp}")
                if len(entries) > 3:
                    lines.append(f"  ... +{len(entries) - 3} more")

    # Idle state
    if isinstance(idle_resp, dict) and idle_resp.get("status") == "ok":
        data = idle_resp.get("data", {})
        is_idle = data.get("is_idle", True)
        if not is_idle:
            blockers = []
            if data.get("pending_vc_transitions", 0) > 0:
                blockers.append(f"{data['pending_vc_transitions']} VC transition(s)")
            if data.get("has_transient_animations"):
                anim = data.get("blocking_anim_key", "unknown")
                blockers.append(f"animation: {anim}")
            if data.get("pending_dispatches", 0) > 0:
                blockers.append(f"{data['pending_dispatches']} pending dispatch(es)")
            if blockers:
                lines.append(f"settling: {', '.join(blockers)}")
        else:
            active_net = data.get("active_requests", 0)
            if active_net > 0:
                lines.append(f"idle (ui), {active_net} request(s) in-flight")

    # Memory delta — always show if we have data
    if isinstance(mem_resp, dict) and mem_resp.get("status") == "ok":
        current_mb = mem_resp.get("data", {}).get("resident_mb", 0.0)
        pre_mb = pre_counts.get("mem_mb", 0.0)
        if current_mb > 0:
            delta_mb = current_mb - pre_mb if pre_mb > 0 else 0
            mem_str = f"memory: {current_mb:.0f}MB"
            if abs(delta_mb) >= 1:
                sign = "+" if delta_mb > 0 else ""
                mem_str += f" ({sign}{delta_mb:.0f}MB)"
                if delta_mb >= 50:
                    mem_str += " \u26a0"
            lines.append(mem_str)

    if not lines:
        return ""
    return "\n--- telemetry ---\n" + "\n".join(lines)


async def act_and_look(
    simulator: Optional[str],
    cmd: str,
    params: Optional[dict] = None,
    timeout: float = 10,
    *,
    send_fn: SendFn,
) -> str:
    """Send a command, then automatically run look to show screen state after the action.
    Returns: action result + screen summary + telemetry. Forces the check-act-verify loop."""
    try:
        host, port, udid = discover_instance(simulator)
    except RuntimeError as e:
        return json.dumps({"status": "error", "error": str(e)}, indent=2)

    # Bind host so downstream telemetry calls reach the right target
    bound_fn = partial(send_fn, host=host) if host != "localhost" else send_fn

    # Snapshot counts before action for telemetry delta
    pre_counts = await snapshot_counts(port, bound_fn)

    # Execute the action
    action_resp = await bound_fn(port, cmd, params, timeout)

    # If the action failed, include screen state + guidance
    if action_resp.get("status") != "ok":
        error_msg = action_resp.get("error", "")
        data_msg = action_resp.get("data", {}).get("message", "")
        err = error_msg or data_msg

        # Crash — don't try to look (app is dead), but fetch crash info
        if "APP CRASHED" in err:
            result = json.dumps(action_resp, indent=2)
            crash_info = await fetch_crash_info(udid)
            if crash_info:
                result += crash_info
            return result

        # Element not found — show what IS on screen
        if "not found" in err.lower() or "no hit-reachable" in err.lower():
            await asyncio.sleep(0.2)
            look_resp = await bound_fn(port, "look", {}, timeout=5)
            screen_summary = format_look(look_resp) if look_resp.get("status") == "ok" else "(look failed)"
            return f"Error: {err}\n\n--- What's actually on screen ---\n{screen_summary}"

        # Connection error
        if "refused" in err.lower() or "connect" in err.lower():
            return f"Error: {err}\n\nPepper is not running. Use `deploy` to launch the app with Pepper injected."

        return json.dumps(action_resp, indent=2)

    # Brief pause for UI to settle after interaction
    await asyncio.sleep(0.3)

    # Auto-look + telemetry in parallel
    look_task = asyncio.create_task(
        bound_fn(port, "look", {}, timeout=5)
    )
    telemetry_task = asyncio.create_task(
        gather_telemetry(port, pre_counts, bound_fn)
    )

    look_resp, telemetry = await asyncio.gather(look_task, telemetry_task, return_exceptions=True)

    if isinstance(look_resp, dict):
        screen_summary = format_look(look_resp) if look_resp.get("status") == "ok" else "(look failed)"
    else:
        screen_summary = "(look failed)"

    if isinstance(telemetry, Exception):
        telemetry = ""

    # Format: action result on top, then screen state, then telemetry
    action_data = action_resp.get("data", {})
    action_summary = action_data.get("description", action_data.get("strategy", cmd))

    result = f"Action: {action_summary}\n\n--- Screen after {cmd} ---\n{screen_summary}"
    if telemetry:
        result += f"\n{telemetry}"
    return result

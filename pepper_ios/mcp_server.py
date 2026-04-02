"""
Pepper MCP Server — exposes Pepper's runtime control as native MCP tools.

Connects to the Pepper dylib's WebSocket server running inside an iOS simulator app.
Each tool maps to a Pepper command, with typed parameters and structured responses.

Usage:
  pepper-mcp                    # via pip install entry point
  python -m pepper_ios.mcp_server  # direct module invocation

Multiple simulators: tools accept an optional `simulator` parameter (UDID).
If omitted and exactly one sim is running, auto-discovers. If multiple, returns
an error listing available sims.
"""

from __future__ import annotations

import asyncio
import json

# Suppress all stdout except MCP protocol — critical for stdio transport
# Logs go to stderr (safe for MCP stdio transport). Set PEPPER_DEBUG=1 for verbose output.
import logging
import os
import sys
from functools import partial
from typing import Optional

from . import pepper_sessions
from .mcp_build import (
    build_app as _build_app,
)
from .mcp_build import (
    build_app_device as _build_app_device,
)
from .mcp_build import (
    deploy_app as _deploy_app,
)
from .mcp_build import (
    find_built_app as _find_built_app,
)
from .mcp_build import (
    install_on_device as _install_on_device,
)
from .mcp_build import (
    launch_on_device as _launch_on_device,
)
from .mcp_build import (
    resolve_simulator as _resolve_simulator,
)
from .mcp_build import (
    verify_device_connected as _verify_device_connected,
)
from .mcp_crash import fetch_crash_info
from .mcp_prompts import register_prompts
from .mcp_tools_accessibility import register_accessibility_tools
from .mcp_tools_biometric import register_biometric_tools
from .mcp_tools_debug import register_debug_tools
from .mcp_tools_dialog import register_dialog_tools
from .mcp_tools_element import register_element_tools
from .mcp_tools_nav import register_nav_tools
from .mcp_tools_network import register_network_tools
from .mcp_tools_perf import register_perf_tools
from .mcp_tools_record import register_record_tools
from .mcp_tools_renders import register_renders_tools
from .mcp_tools_script import register_script_tools
from .mcp_tools_sim import register_sim_tools
from .mcp_tools_state import register_state_tools
from .mcp_tools_system import register_system_tools
from .pepper_websocket import CrashError, make_command
from .pepper_websocket import send_command as ws_send_command

_log_level = logging.DEBUG if os.environ.get("PEPPER_DEBUG") else logging.WARNING
logging.basicConfig(
    stream=sys.stderr,
    level=_log_level,
    format="[pepper] %(asctime)s %(levelname)s %(name)s: %(message)s",
    datefmt="%H:%M:%S",
)
logger = logging.getLogger("pepper_mcp")

try:
    from mcp.server.fastmcp import FastMCP
    from pydantic import Field
except ImportError:
    print("Error: 'mcp' package required. Install with: pip install mcp", file=sys.stderr)
    sys.exit(1)

try:
    import websockets
except ImportError:
    print("Error: 'websockets' package required. Install with: pip install websockets", file=sys.stderr)
    sys.exit(1)

# ---------------------------------------------------------------------------
# Config from .env (shared via pepper_common)
# ---------------------------------------------------------------------------

from .pepper_common import (
    PEPPER_DIR,
    discover_instance,
    get_config,
    json_dumps,
    load_env,
    resolve_adapter_dir,
)


def _active_adapter_type() -> str:
    """Resolve the active adapter type — session context first, .env fallback."""
    from .mcp_build import get_session_context
    ctx = get_session_context()
    if ctx.get("adapter_type"):
        return ctx["adapter_type"]
    return get_config().get("adapter_type", "generic")


def load_adapter_tools() -> list[dict]:
    """Load adapter-specific tool definitions.

    Searches (in order):
    1. ~/.pepper/adapters/{type}/tools.json (co-located with adapter)
    2. ~/.pepper/tools/{adapter_type}.json (legacy location)

    Uses the session's active adapter (set by deploy_sim), falling back to .env.
    """
    adapter_type = _active_adapter_type()
    if adapter_type == "generic":
        return []

    # Find the tools file — adapter dir first, legacy fallback
    adapter_dir = resolve_adapter_dir(adapter_type)
    tools_path = None
    if adapter_dir:
        candidate = os.path.join(adapter_dir, "tools.json")
        if os.path.exists(candidate):
            tools_path = candidate
    if not tools_path:
        candidate = os.path.join(os.path.expanduser("~"), ".pepper", "tools", f"{adapter_type}.json")
        if os.path.exists(candidate):
            tools_path = candidate
    if not tools_path:
        return []

    try:
        with open(tools_path) as f:
            tools = json.load(f)
        if not isinstance(tools, list):
            return []
        # Resolve placeholders. APP_REPO can be set in .env or shell env.
        # Falls back to APP_WORKSPACE dirname if available.
        env = load_env()
        config = get_config()
        workspace = config.get("workspace", "")
        app_repo = (
            env.get("APP_REPO") or os.environ.get("APP_REPO") or (os.path.dirname(workspace) if workspace else "")
        )
        replacements = {
            "{app_repo}": app_repo,
            "{pepper_dir}": PEPPER_DIR,
            "{workspace}": workspace,
        }
        for tool in tools:
            cmd = tool.get("command", "")
            for key, val in replacements.items():
                cmd = cmd.replace(key, val)
            tool["command"] = cmd
        return tools
    except (json.JSONDecodeError, OSError):
        return []


def load_adapter_preamble() -> str:
    """Load adapter-specific MCP preamble.

    Searches (in order):
    1. ~/.pepper/adapters/{type}/mcp-preamble.md (adapter repo)
    2. ADAPTER_PATH/mcp-preamble.md (legacy external path)
    3. dylib/{adapter_type}/mcp-preamble.md (in-tree fallback)
    Returns the content or empty string if no preamble found.
    """
    adapter_type = _active_adapter_type()
    if adapter_type == "generic":
        return ""

    # Check resolved adapter dir (covers both ~/.pepper/adapters/ and ADAPTER_PATH)
    adapter_dir = resolve_adapter_dir(adapter_type)
    if adapter_dir:
        preamble = os.path.join(adapter_dir, "mcp-preamble.md")
        if os.path.exists(preamble):
            try:
                with open(preamble) as f:
                    return f.read().strip()
            except OSError:
                pass

    # Fallback: in-tree
    preamble = os.path.join(PEPPER_DIR, "dylib", adapter_type, "mcp-preamble.md")
    if os.path.exists(preamble):
        try:
            with open(preamble) as f:
                return f.read().strip()
        except OSError:
            pass
    return ""


# ---------------------------------------------------------------------------
# WebSocket command sender
# ---------------------------------------------------------------------------


async def send_command(
    port: int, cmd: str, params: dict | None = None, timeout: float = 10, host: str = "localhost", retries: int = 0
) -> dict:
    """Send a command to Pepper's WebSocket server and return the response.

    Wraps pepper_websocket.send_command with MCP-appropriate error handling
    (returns error dicts instead of raising).

    Args:
        retries: Number of retry attempts for transient connection failures. Default 0.
    """
    msg = make_command(cmd, params)
    addr = f"{host}:{port}"
    logger.debug("send cmd=%s params=%s addr=%s timeout=%s retries=%d", cmd, params, addr, timeout, retries)
    try:
        result = await ws_send_command(host, port, msg, timeout=timeout, retries=retries)
        if result.get("status") != "ok":
            logger.warning("cmd=%s error=%s", cmd, result.get("error", result.get("data")))
        return result
    except asyncio.TimeoutError:
        logger.warning("cmd=%s timed out after %ss", cmd, timeout)
        return {"status": "error", "error": f"Command timed out after {timeout}s"}
    except ConnectionRefusedError:
        logger.warning("cmd=%s connection refused at %s", cmd, addr)
        return {"status": "error", "error": f"Connection refused at {addr}. Is Pepper running?"}
    except CrashError as e:
        logger.warning("cmd=%s crash: %s", cmd, e)
        return {"status": "error", "error": f"{e} Crash log will be auto-attached below."}
    except Exception as e:
        err_str = str(e)
        logger.warning("cmd=%s exception: %s", cmd, err_str)
        if "close frame" in err_str or "connection" in err_str.lower():
            return {
                "status": "error",
                "error": f"APP CRASHED. The '{cmd}' command likely crashed the app ({err_str}). "
                f"Investigate the crash before retrying.",
            }
        return {"status": "error", "error": err_str}


async def resolve_and_send(
    simulator: str | None, cmd: str, params: dict | None = None, timeout: float = 10
) -> dict:
    """Resolve instance and send command. Returns response dict. Auto-appends crash info on APP CRASHED.

    The simulator parameter accepts any Pepper instance identifier — simulator UDID or device UDID.
    Discovery checks both simulator port files and device registrations.

    Note: most MCP tool handlers call resolve_and_send_json() instead, which
    serializes the dict to a JSON string for FastMCP return-type compliance.
    """
    logger.debug("resolve_and_send cmd=%s simulator=%s params=%s", cmd, simulator, params)
    try:
        # Use session affinity: if no explicit sim, resolve via _resolve_simulator
        # which remembers the last-used sim (set by deploy_sim).
        resolved = simulator
        if not resolved:
            try:
                resolved = _resolve_simulator(None)
            except RuntimeError:
                pass  # fall through to discover_instance(None)
        host, port, udid = discover_instance(resolved)
    except RuntimeError as e:
        logger.warning("resolve_and_send cmd=%s discovery failed: %s", cmd, e)
        return {"status": "error", "error": str(e)}
    resp = await send_command(port, cmd, params, timeout, host=host)
    # Auto-fetch crash info when app crashes
    error = resp.get("error", "")
    if "APP CRASHED" in error:
        crash_info = await fetch_crash_info(udid)
        if crash_info:
            resp["crash_info"] = crash_info
    return resp


async def resolve_and_send_json(
    simulator: str | None, cmd: str, params: dict | None = None, timeout: float = 10
) -> str:
    """Like resolve_and_send but returns a JSON string.

    Use this from MCP tool handlers that declare -> str return type.
    FastMCP validates return types via pydantic — returning a dict when the
    handler declares -> str causes a validation error.
    """
    resp = await resolve_and_send(simulator, cmd, params, timeout)
    return json_dumps(resp)


# Monitors known to be active, updated each act_and_look cycle.
# None means unknown (first call); after that, a frozenset of active monitor names.
_known_active_monitors: frozenset[str] | None = None


def reset_monitor_state():
    """Reset cached monitor state.

    Call after deploy or reconnection so stale monitor status from a
    previous app session doesn't leak into the new one. The next
    _snapshot_counts call will re-probe all monitors.
    """
    global _known_active_monitors
    _known_active_monitors = None

# Monitor definitions: (name, count_key_in_response, count_key_in_result, active_key_in_result)
_MONITOR_DEFS = (
    ("network", "total_recorded", "net_total", "net_active"),
    ("console", "total_captured", "console_total", "console_active"),
    ("renders", "event_count", "render_events", "renders_active"),
    ("notifications", "total_tracked", "notif_total", "notif_active"),
    ("timers", "total_tracked", "timer_total", "timers_active"),
)


async def _snapshot_counts(port: int, send_fn) -> dict:
    """Snapshot counts for active monitors + memory before an action.

    On the first call, queries all monitors to discover which are active.
    On subsequent calls, skips monitors known to be inactive.
    """
    global _known_active_monitors

    # Decide which monitors to query
    to_query = {name for name, *_ in _MONITOR_DEFS} if _known_active_monitors is None else set(_known_active_monitors)

    # Build concurrent queries — only active monitors + memory (always useful)
    coro_keys: list[str] = []
    coros: list = []
    for name, *_ in _MONITOR_DEFS:
        if name in to_query:
            coro_keys.append(name)
            coros.append(send_fn(port, name, {"action": "status"}, timeout=2))
    coro_keys.append("memory")
    coros.append(send_fn(port, "memory", timeout=2))

    results = await asyncio.gather(*coros, return_exceptions=True)
    resp_map = dict(zip(coro_keys, results))

    # Extract counts and active flags
    counts: dict = {"mem_mb": 0.0}
    active_set: set[str] = set()
    for name, count_key, result_key, active_key in _MONITOR_DEFS:
        r = resp_map.get(name)
        if isinstance(r, dict) and r.get("status") == "ok":
            data = r.get("data", {})
            counts[result_key] = data.get(count_key, 0)
            is_active = data.get("active", False)
            counts[active_key] = is_active
            if is_active:
                active_set.add(name)
        else:
            counts[result_key] = 0
            counts[active_key] = False

    mem_resp = resp_map.get("memory")
    if isinstance(mem_resp, dict) and mem_resp.get("status") == "ok":
        counts["mem_mb"] = mem_resp.get("data", {}).get("resident_mb", 0.0)

    _known_active_monitors = frozenset(active_set)
    return counts


async def _gather_telemetry(port: int, pre_counts: dict, send_fn) -> str:
    """Gather ambient telemetry and format as compact summary.

    Compares current counts against pre-action snapshot to show only new activity.
    Skips WebSocket queries for monitors that weren't active in the pre-action snapshot.
    Tracks: network, console, renders, notifications, timers, idle state, memory.
    """
    lines: list[str] = []

    net_active = pre_counts.get("net_active", False)
    console_active = pre_counts.get("console_active", False)
    renders_active = pre_counts.get("renders_active", False)
    notif_active = pre_counts.get("notif_active", False)
    timers_active = pre_counts.get("timers_active", False)

    # Build queries — only for active monitors + always-on idle/memory
    coro_keys: list[str] = []
    coros: list = []

    if net_active:
        coro_keys += ["net_resp", "net_status"]
        coros += [
            send_fn(port, "network", {"action": "log", "limit": 10}, timeout=2),
            send_fn(port, "network", {"action": "status"}, timeout=2),
        ]
    if console_active:
        coro_keys += ["console_resp", "console_status"]
        coros += [
            send_fn(port, "console", {"action": "log", "limit": 10}, timeout=2),
            send_fn(port, "console", {"action": "status"}, timeout=2),
        ]

    coro_keys.append("idle_resp")
    coros.append(send_fn(port, "wait_idle", {"debug": True}, timeout=2))
    coro_keys.append("mem_resp")
    coros.append(send_fn(port, "memory", timeout=2))

    if renders_active:
        coro_keys.append("renders_resp")
        coros.append(send_fn(port, "renders", {"action": "status"}, timeout=2))
    if notif_active:
        coro_keys.append("notif_resp")
        coros.append(send_fn(port, "notifications", {"action": "status"}, timeout=2))
    if timers_active:
        coro_keys.append("timers_resp")
        coros.append(send_fn(port, "timers", {"action": "status"}, timeout=2))

    results = await asyncio.gather(*coros, return_exceptions=True)
    r = dict(zip(coro_keys, results))

    # Network requests that fired during the action
    net_status = r.get("net_status")
    if isinstance(net_status, dict) and net_status.get("status") == "ok":
        new_count = net_status.get("data", {}).get("total_recorded", 0) - pre_counts.get("net_total", 0)
        net_resp = r.get("net_resp")
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
        dupes = net_status.get("data", {}).get("duplicate_warnings", [])
        for d in dupes:
            if d.get("seconds_ago", 999) < 10:  # Only show recent duplicates
                endpoint = d.get("endpoint", "?")
                count = d.get("count", 0)
                window = d.get("window_ms", 0)
                lines.append(f"\u26a0 overfiring: {endpoint} called {count}x in {window}ms")

    # Console output during the action
    console_status = r.get("console_status")
    if isinstance(console_status, dict) and console_status.get("status") == "ok":
        new_count = console_status.get("data", {}).get("total_captured", 0) - pre_counts.get("console_total", 0)
        console_resp = r.get("console_resp")
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

    # Idle state — only surface when something is actively blocking or many requests in-flight
    idle_resp = r.get("idle_resp")
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

    # Render count delta — only when tracking is active and renders occurred
    renders_resp = r.get("renders_resp")
    if isinstance(renders_resp, dict) and renders_resp.get("status") == "ok":
        rdata = renders_resp.get("data", {})
        if rdata.get("active"):
            new_renders = rdata.get("event_count", 0) - pre_counts.get("render_events", 0)
            if new_renders > 0:
                render_str = f"renders: {new_renders} event(s)"
                if new_renders >= 20:
                    render_str += " \u26a0 excessive"
                lines.append(render_str)

    # Notification delta — only when tracking is active
    notif_resp = r.get("notif_resp")
    if isinstance(notif_resp, dict) and notif_resp.get("status") == "ok":
        ndata = notif_resp.get("data", {})
        if ndata.get("active"):
            new_notifs = ndata.get("total_tracked", 0) - pre_counts.get("notif_total", 0)
            if new_notifs > 0:
                lines.append(f"notifications: {new_notifs} posted")

    # Timer delta — only when tracking is active
    timers_resp = r.get("timers_resp")
    if isinstance(timers_resp, dict) and timers_resp.get("status") == "ok":
        tdata = timers_resp.get("data", {})
        if tdata.get("active"):
            new_timers = tdata.get("total_tracked", 0) - pre_counts.get("timer_total", 0)
            if new_timers > 0:
                lines.append(f"timers: {new_timers} created")

    # Memory delta — only show when significant (>= 5MB change or >= 50MB spike warning)
    mem_resp = r.get("mem_resp")
    if isinstance(mem_resp, dict) and mem_resp.get("status") == "ok":
        current_mb = mem_resp.get("data", {}).get("resident_mb", 0.0)
        pre_mb = pre_counts.get("mem_mb", 0.0)
        if current_mb > 0 and pre_mb > 0:
            delta_mb = current_mb - pre_mb
            if abs(delta_mb) >= 5:
                sign = "+" if delta_mb > 0 else ""
                mem_str = f"memory: {current_mb:.0f}MB ({sign}{delta_mb:.0f}MB)"
                if delta_mb >= 50:
                    mem_str += " \u26a0"
                lines.append(mem_str)

    if not lines:
        return ""
    return "\n--- telemetry ---\n" + "\n".join(lines)


def _ax_detect_safe() -> dict | None:
    """Run AX probe for SpringBoard dialog detection, returning None on failure."""
    try:
        from .pepper_ax import detect_dialog

        return detect_dialog()
    except Exception:
        return None


def _look_error_reason(resp) -> str | None:
    """Extract an error reason from a look response, or None if it succeeded."""
    if isinstance(resp, Exception):
        return f"{type(resp).__name__}: {resp}"
    if not isinstance(resp, dict):
        return "unexpected response type"
    if resp.get("status") == "ok":
        return None
    return resp.get("error") or resp.get("data", {}).get("message") or "unknown error"


async def act_and_look(simulator: str | None, cmd: str, params: dict | None = None, timeout: float = 10) -> list:
    """Send a command, then automatically run look to show screen state after the action.
    Returns: action result + screen summary + telemetry. Forces the check-act-verify loop."""
    from .pepper_format import format_look_compact, format_look_slim

    logger.debug("act_and_look cmd=%s simulator=%s params=%s", cmd, simulator, params)
    try:
        host, port, udid = discover_instance(simulator)
    except RuntimeError as e:
        logger.warning("act_and_look cmd=%s discovery failed: %s", cmd, e)
        return json_dumps({"status": "error", "error": str(e)})

    # Bind host so downstream telemetry calls reach the right target
    bound_fn = partial(send_command, host=host) if host != "localhost" else send_command

    # Snapshot counts before action for telemetry delta
    pre_counts = await _snapshot_counts(port, bound_fn)

    # Execute the action
    action_resp = await bound_fn(port, cmd, params, timeout)

    # Record the step if a script recording is active
    from .mcp_scripts import maybe_record_step
    maybe_record_step(cmd, params, sim_key=udid or "default")

    # If the action failed, include screen state + guidance
    if action_resp.get("status") != "ok":
        error_msg = action_resp.get("error", "")
        data_msg = action_resp.get("data", {}).get("message", "")
        err = error_msg or data_msg

        from mcp.types import TextContent

        # Crash — don't try to look (app is dead), but fetch crash info
        if "APP CRASHED" in err:
            result = json_dumps(action_resp)
            crash_info = await fetch_crash_info(udid)
            if crash_info:
                result += crash_info
            return [TextContent(type="text", text=result)]

        # Element not found — show what IS on screen
        if "not found" in err.lower() or "no hit-reachable" in err.lower():
            await asyncio.sleep(0.2)
            look_resp = await bound_fn(port, "look", {}, timeout=5)
            if look_resp.get("status") == "ok":
                screen_summary = format_look_slim(look_resp)
            else:
                reason = _look_error_reason(look_resp)
                screen_summary = f"(look failed: {reason})"
            return [TextContent(type="text", text=f"Error: {err}\n--- What's actually on screen ---\n{screen_summary}")]

        # Connection error
        if "refused" in err.lower() or "connect" in err.lower():
            return [
                TextContent(
                    type="text",
                    text=f"Error: {err}\n\nPepper is not running. Use `deploy_sim` to launch the app with Pepper injected.",
                )
            ]

        return [TextContent(type="text", text=json_dumps(action_resp))]

    # Brief pause for UI to settle after interaction.
    # Navigation commands (dismiss, back, navigate) need more time for
    # VC transitions + SwiftUI re-layout to complete. Dismiss is the
    # heaviest — modal teardown + underlying view re-render.
    if cmd == "dismiss":
        settle = 1.5
    elif cmd in ("back", "navigate", "dismiss_keyboard"):
        settle = 0.8
    else:
        settle = 0.3
    await asyncio.sleep(settle)

    # Auto-look + telemetry + AX probe in parallel
    look_task = asyncio.create_task(bound_fn(port, "look", {}, timeout=8))
    telemetry_task = asyncio.create_task(_gather_telemetry(port, pre_counts, bound_fn))
    ax_task = asyncio.ensure_future(asyncio.get_running_loop().run_in_executor(None, _ax_detect_safe))

    look_resp, telemetry = await asyncio.gather(look_task, telemetry_task, return_exceptions=True)

    # Detect look failure and extract reason for diagnostics
    look_error_reason = _look_error_reason(look_resp)

    # Retry once if look failed — animation/transition may still be in progress
    if look_error_reason is not None:
        logger.warning("Auto-look failed after %s: %s — retrying in 500ms", cmd, look_error_reason)
        await asyncio.sleep(0.5)
        try:
            look_resp = await bound_fn(port, "look", {}, timeout=8)
            retry_err = _look_error_reason(look_resp)
            look_error_reason = None if retry_err is None else f"{look_error_reason} (retry also failed: {retry_err})"
        except Exception as e:
            look_error_reason = f"{look_error_reason} (retry exception: {e})"

    # Collect AX probe result for SpringBoard dialog detection
    try:
        ax_result = await asyncio.wait_for(ax_task, timeout=0.3)
    except (asyncio.TimeoutError, Exception):
        ax_result = None

    # Inject SpringBoard dialog into look response if AX detected one
    # and the dylib didn't already include system_dialog_blocking.
    if isinstance(look_resp, dict):
        look_data = look_resp.get("data", look_resp)
        if ax_result and ax_result.get("detected") and not look_data.get("system_dialog_blocking"):
            look_data["system_dialog_blocking"] = {
                "warning": "springboard_dialog_detected",
                "description": "A SpringBoard system dialog is overlaying the app. Use dialog dismiss_system to handle it.",
                "dialogs": [{"title": "System Dialog", "buttons": ax_result.get("buttons", [])}],
                "suggested_actions": [
                    "dialog dismiss_system",
                    "dialog detect_system",
                ],
            }
        if look_resp.get("status") == "ok":
            screen_summary = format_look_compact(look_resp)
        else:
            screen_summary = f"(look failed: {look_error_reason})"
    else:
        screen_summary = f"(look failed: {look_error_reason or 'no response from dylib'})"

    if isinstance(telemetry, Exception):
        telemetry = ""

    # Format: action result on top, then screen state, then telemetry
    action_data = action_resp.get("data", {})
    action_summary = action_data.get("description", action_data.get("strategy", cmd))

    result = f"Action: {action_summary}\n--- Screen after {cmd} ---\n{screen_summary}"
    if telemetry:
        result += f"\n{telemetry.lstrip()}"
    from mcp.types import TextContent

    return [TextContent(type="text", text=result)]


# ---------------------------------------------------------------------------
# MCP Server
# ---------------------------------------------------------------------------

_CORE_INSTRUCTIONS = (
    "Pepper controls a running iOS app via a dylib injected into the simulator. "
    "Use `look` to see what's on screen, `tap` to interact, `vars` to inspect/mutate state, "
    "`layers` to debug rendering, `screen` for the current screen name. "
    "All tools accept an optional `simulator` UDID parameter for multi-sim setups.\n\n"
    "RULES:\n"
    "- NEVER screenshot. Use `look` instead. Always.\n"
    "- `look` first, always. Before tapping, navigating, or asserting.\n"
    "- Use `look visual=true` to include a simulator screenshot alongside the structured data for visual validation.\n"
    "- Action tools (tap, scroll, navigate, back, input) auto-include screen state in their response. Read it.\n"
    "- To check property values: use `vars_inspect`, NOT print statements. No rebuild needed.\n"
    "- To check API traffic: use `network` start + log, NOT print statements.\n"
    "- To capture app logs (print + NSLog): use `console` start + log.\n"
    "- If a command returns APP CRASHED: investigate the crash, do NOT just redeploy.\n"
    "- If an element isn't found: the screen state is in the error. Read it before retrying.\n"
    "- Use `deploy_sim(workspace, simulator)` to build + deploy. NEVER use raw `simctl launch`.\n\n"
    "TIPS:\n"
    "- Always `look` before interacting to confirm screen state.\n"
    "- Action tools (tap, scroll, navigate) auto-include screen state in response — read it.\n"
    "- For recordings, use `pepper-ctl tap --point x,y` for fast chained actions (no look overhead).\n"
    "- Screenshots go to the repo where the PR lives, not pepper's repo.\n\n"
    "WORKFLOW GUIDES (read the resource when you need it):\n"
    "- pepper://guides/pr-validation — PR test plan validation workflow\n"
    "- pepper://guides/screen-recording — screen recording and upload workflow\n"
    "- pepper://guides/launching — app build and launch workflow"
)

_adapter_preamble = load_adapter_preamble()
_instructions = _CORE_INSTRUCTIONS + ("\n\n" + _adapter_preamble if _adapter_preamble else "")

mcp = FastMCP("pepper", instructions=_instructions)


# ---------------------------------------------------------------------------
# Workflow guide resources (on-demand, not in every session's instructions)
# ---------------------------------------------------------------------------

_PR_VALIDATION_GUIDE = (
    "PR TEST PLAN VALIDATION:\n"
    "When asked to validate a PR, use this workflow:\n"
    "1. Read the PR: `gh pr view NNNN --repo owner/repo` for description, "
    "`gh pr diff NNNN --repo owner/repo` for changes.\n"
    "2. Parse the test plan — each checkbox is a validation item.\n"
    "3. For each item:\n"
    "   a. Navigate to the relevant screen (deeplink or tap sequence).\n"
    "   b. Perform the interaction described in the test item.\n"
    "   c. Verify the expected outcome with `look` (check text, elements, state).\n"
    "   d. Capture screenshot: `look visual=true screenshot_quality=high "
    "save_screenshot=/tmp/pr-NNNN-item.jpg`\n"
    "4. Upload all screenshots: `python3 <PEPPER_DIR>/tools/upload-screenshot "
    "--repo owner/repo --prefix pr-NNNN --markdown /tmp/pr-NNNN-*.jpg`\n"
    "5. Update PR description: `gh pr edit NNNN --repo owner/repo --body '...'` "
    "— check off validated items.\n"
    "   Add a `### Screenshots` section (not 'Evidence'). Use HTML img tags with "
    "width=200 for thumbnails.\n"
    "   Label each screenshot with a bold caption above it. Example:\n"
    '   `**Flag off** <img src="URL" width=200> **Flag on** <img src="URL" width=200>`'
)

_SCREEN_RECORDING_GUIDE = (
    "SCREEN RECORDING:\n"
    "For test items that need interaction sequences (toggle persistence, navigation flows):\n"
    "- `record action=start` → do interactions → `record action=stop output=/tmp/clip.mp4`\n"
    "- For tight clips: explore first with `look`, then chain taps with animation "
    "delays (0.3-0.7s per action).\n"
    "- Upload videos via Playwright MCP (browser automation) to get user-attachments "
    "URLs that autoplay in PRs.\n"
    "- Upload screenshots via `upload-screenshot` tool (release assets, always works).\n"
    "- See /validate-pr skill for the full browser upload workflow."
)

_LAUNCHING_GUIDE = (
    "LAUNCHING THE APP:\n"
    "`deploy_sim` builds, installs, launches with Pepper, and returns screen state.\n"
    "Required params: workspace (path to .xcworkspace) and simulator (UDID).\n"
    "Use `simulator action=list` to find available simulator UDIDs.\n"
    "NEVER use raw `simctl launch` — it skips Pepper injection.\n"
    "Bundle ID is auto-detected from the built .app. Pass it explicitly only if needed."
)

_ACTIONS_REFERENCE = """\
ACTION REFERENCE — detailed docs for multi-action tools.

## heap
- classes: Search live heap classes by name pattern. Params: pattern, limit.
- controllers: List live UIViewControllers.
- find: Find singleton or specific instance. Params: class_name.
- inspect: Show properties of a live object. Params: class_name.
- read: Read a KVC key path on an object. Params: class_name, key_path (e.g. 'camera.zoom').
- baseline: Save current instance counts for later comparison.
- check: Compare current counts against baseline, flag growth. Params: threshold (min growth, default 1).
- diff: Show instance count changes since last snapshot. Params: min_growth (default 1).
- snapshot: Take a heap snapshot.
- snapshot_clear: Clear saved snapshots.
- snapshot_status: Check snapshot state.

## renders
- start: Begin tracking SwiftUI body evaluations.
- stop: Stop tracking.
- status: Check if tracking is active.
- log: Return captured render events. Params: limit (default 100), since_ms, filter.
- clear: Clear captured events.
- counts: Show per-view render counts.
- snapshot: Take a render-count snapshot for later diff.
- diff: Compare current counts against snapshot.
- reset: Clear counts and snapshots.
- ag_probe: Probe AttributeGraph.
- ag_server: Start AG debug server.
- ag_dump: Dump AG state. Params: name.
- signpost: Install or drain os_signpost probes. Params: sub (install | drain).
- why: Explain why a view re-rendered.

## notifications
- start: Begin tracking NSNotificationCenter observers.
- stop: Stop tracking.
- list: List registered observers. Params: filter_text, limit.
- counts: Show notification counts by name.
- post: Post a notification. Params: name (required), user_info (JSON string).
- events: List posted notification events. Params: filter_text, limit.
- status: Check tracking state.
- clear: Clear recorded data.

## timers
- start: Begin tracking NSTimer and CADisplayLink instances.
- stop: Stop tracking.
- list: List active timers. Params: filter_text, limit.
- invalidate: Cancel a timer. Params: timer_id (e.g. 'timer_3', 'dlink_1').
- status: Check tracking state.
- clear: Clear recorded data.

## simulator
- list: Show booted simulators with Pepper connection status.
- install: Install app. Params: app_path.
- uninstall: Remove app. Params: bundle_id.
- location: Set GPS coordinates. Params: latitude, longitude. (0,0 clears.)
- permissions: Grant/revoke a permission. Params: permission (photos, camera, microphone, \
contacts, calendar, reminders, location-always, location-when-in-use, notifications, health), \
permission_value (grant | revoke | reset), bundle_id.
- biometrics: Enroll Face ID or send match. Params: biometric_type (enroll | match).
- privacy_reset: Reset all privacy permissions. Params: bundle_id.
- open_url: Open a URL/deep link. Params: url.
- addmedia: Add image/video to camera roll. Params: media_path.
- boot: Boot a simulator.
- shutdown: Shut down a simulator.
- erase: Factory-reset a simulator.
- status_bar: Override status bar. Params: time (e.g. '09:41'), clear_time (bool).

## vars_inspect
- list: List tracked ViewModels found via runtime scanning.
- dump: Show @Published properties of a ViewModel. Params: class_name.
- mirror: Show all properties (including non-Published) via Swift Mirror. Params: class_name.
- set: Mutate a live property value. Params: path (e.g. 'MyVM.flag'), value.
- discover: Re-scan the runtime for new ViewModel instances.

## sandbox
- paths: Show app container directories (Documents, Caches, Library, tmp, Bundle).
- list: List files in a directory. Params: path, recursive.
- read: Read file contents (auto-detects text/plist/JSON/binary). Params: path, max_length.
- write: Write file contents. Params: path, content, base64.
- delete: Delete a file. Params: path.
- info: Show file attributes (size, dates, permissions). Params: path.
- size: Show directory size summary. Params: path.
"""


@mcp.resource("pepper://guides/pr-validation")
def pr_validation_guide() -> str:
    """PR test plan validation workflow: read PR, validate each checkbox, capture screenshots, update PR."""
    return _PR_VALIDATION_GUIDE


@mcp.resource("pepper://guides/screen-recording")
def screen_recording_guide() -> str:
    """Screen recording and video upload workflow for PR evidence."""
    return _SCREEN_RECORDING_GUIDE


@mcp.resource("pepper://guides/launching")
def launching_guide() -> str:
    """App build and launch workflow using deploy_sim."""
    return _LAUNCHING_GUIDE


@mcp.resource("pepper://reference/actions")
def actions_reference() -> str:
    """Detailed action reference for multi-action tools (heap, renders, notifications, timers, simulator)."""
    return _ACTIONS_REFERENCE


# ---------------------------------------------------------------------------
# Dynamic adapter tools (from ~/.pepper/tools/{adapter_type}.json)
# ---------------------------------------------------------------------------


def _register_adapter_tools():
    """Register adapter-provided tools as MCP tools that shell out to commands."""
    tools = load_adapter_tools()
    for tool_def in tools:
        name = tool_def.get("name", "")
        description = tool_def.get("description", "")
        command = tool_def.get("command", "")
        timeout = tool_def.get("timeout", 120)
        if not name or not command:
            continue

        # Create a closure that captures this tool's command
        def make_handler(cmd, cmd_timeout):
            async def handler(
                args: str = Field(default="", description="Additional arguments to append to the command"),
            ) -> str:
                full_cmd = cmd
                if args:
                    full_cmd += " " + args
                try:
                    proc = await asyncio.create_subprocess_shell(
                        full_cmd,
                        stdout=asyncio.subprocess.PIPE,
                        stderr=asyncio.subprocess.PIPE,
                    )
                    stdout, stderr = await asyncio.wait_for(proc.communicate(), timeout=cmd_timeout)
                    output = stdout.decode(errors="replace")
                    err = stderr.decode(errors="replace")
                    result = ""
                    if output:
                        result += output
                    if err:
                        result += ("\n--- stderr ---\n" + err) if result else err
                    if proc.returncode != 0:
                        result += f"\n[exit code {proc.returncode}]"
                    return result or "(no output)"
                except asyncio.TimeoutError:
                    return f"Command timed out after {cmd_timeout}s"
                except Exception as e:
                    return f"Error: {e}"

            return handler

        handler = make_handler(command, timeout)
        mcp.tool(name=name, description=description)(handler)


_register_adapter_tools()


register_nav_tools(mcp, send_command, resolve_and_send, act_and_look)
register_state_tools(mcp, resolve_and_send_json)
register_debug_tools(mcp, resolve_and_send_json)
register_network_tools(mcp, resolve_and_send_json)
register_perf_tools(mcp, resolve_and_send_json)
register_accessibility_tools(mcp, resolve_and_send_json)
register_renders_tools(mcp, resolve_and_send_json)
register_system_tools(mcp, resolve_and_send_json, act_and_look)
# dialog needs raw dict for _dismiss_system_dialog + detect_system internal logic
register_dialog_tools(mcp, resolve_and_send, _resolve_simulator)
register_element_tools(mcp, resolve_and_send_json, act_and_look)
register_record_tools(mcp)
register_sim_tools(mcp, resolve_and_send_json, _resolve_simulator)
register_biometric_tools(mcp, _resolve_simulator)
register_script_tools(mcp, act_and_look, resolve_and_send_json)
register_prompts(mcp)


@mcp.tool()
async def wait_for(
    simulator: str | None = Field(default=None, description="Simulator UDID"),
    element: str | None = Field(default=None, description="Accessibility ID of element to wait for"),
    state: str | None = Field(default=None, description="State to wait for: visible (default), exists, has_value"),
    value: str | None = Field(default=None, description="Expected value (for has_value state)"),
    text: str | None = Field(default=None, description="Wait for text to appear on screen (alternative to element)"),
    screen: str | None = Field(default=None, description="Wait for a specific screen ID (alternative to element)"),
    predicate: str | None = Field(default=None, description="NSPredicate format string to match elements (e.g. \"label == 'Submit' AND enabled == true\"). Same syntax as find tool."),
    expect: str | None = Field(default=None, description="For predicate waits: match (default, wait for ≥1 match) or gone (wait for 0 matches)"),
    timeout_ms: int | None = Field(default=None, description="Timeout in milliseconds (default: 5000)"),
) -> str:
    """Wait for a condition — element visible, text appears, screen changes, or predicate match/gone. Use after actions that trigger async UI updates."""
    until: dict = {}
    if element:
        until["element"] = element
        if state:
            until["state"] = state
        if value:
            until["value"] = value
    elif text:
        until["text"] = text
    elif screen:
        until["screen"] = screen
    elif predicate:
        until["predicate"] = predicate
        if expect:
            until["expect"] = expect
    else:
        return "Error: specify element, text, screen, or predicate to wait for"
    params: dict = {"until": until}
    if timeout_ms is not None:
        params["timeout_ms"] = timeout_ms
    return await resolve_and_send_json(simulator, "wait_for", params, timeout=max(15, (timeout_ms or 5000) / 1000 + 2))


@mcp.tool()
async def wait_idle(
    simulator: str | None = Field(default=None, description="Simulator UDID"),
    timeout_ms: int | None = Field(default=None, description="Timeout in milliseconds (default: 3000)"),
    include_network: bool = Field(default=False, description="Also wait for pending network requests"),
    debug: bool = Field(default=False, description="Return what's blocking idle instead of waiting"),
) -> str:
    """Wait for the app to become idle — no animations or pending transitions. Use before inspecting after complex interactions."""
    params: dict = {}
    if timeout_ms is not None:
        params["timeout_ms"] = timeout_ms
    if include_network:
        params["include_network"] = True
    if debug:
        params["debug"] = True
    return await resolve_and_send_json(simulator, "wait_idle", params, timeout=max(10, (timeout_ms or 3000) / 1000 + 2))


# ---------------------------------------------------------------------------
# Build / deploy / iterate tools (logic in mcp_build.py)
# ---------------------------------------------------------------------------


@mcp.tool()
async def build_sim(
    workspace: str = Field(description="Absolute path to the .xcworkspace to build"),
    simulator: str = Field(description="Simulator UDID for -destination"),
    scheme: str | None = Field(default=None, description="Build scheme (default: from .env APP_SCHEME)"),
) -> str:
    """Compile the iOS app for simulator. Build only — does not install or launch. Use deploy_sim to build + deploy."""
    success, message = await _build_app(workspace, scheme, simulator)
    return message


@mcp.tool()
async def build_hardware(
    workspace: str = Field(description="Absolute path to the .xcworkspace to build"),
    scheme: str | None = Field(default=None, description="Build scheme (default: from .env APP_SCHEME)"),
    device: str | None = Field(
        default=None, description="Device xcodebuild ID (default: from .env DEVICE_XCODEBUILD_ID)"
    ),
    install: bool = Field(default=True, description="Install on device after building"),
    launch: bool = Field(default=True, description="Launch app after installing"),
) -> str:
    """Build the iOS app for a physical device connected via USB/WiFi. Not for simulators — use build_sim instead."""
    cfg = get_config()
    devicectl_uuid = cfg["device_devicectl_uuid"]

    if not devicectl_uuid and (install or launch):
        return "No device devicectl UUID configured. Set DEVICE_DEVICECTL_UUID in pepper/.env"

    # Verify device is connected before building (fail fast)
    if install or launch:
        connected, msg = await _verify_device_connected(devicectl_uuid)
        if not connected:
            return msg

    # Build
    success, build_msg = await _build_app_device(workspace, scheme, device)
    if not success:
        return build_msg

    parts = [build_msg]

    if install:
        app_path = _find_built_app(workspace, platform="iphoneos")
        if not app_path:
            return f"{build_msg}\n\nBuild succeeded but could not find .app in DerivedData (Debug-iphoneos/)"
        ok, msg = await _install_on_device(devicectl_uuid, app_path)
        parts.append(msg)
        if not ok:
            return "\n".join(parts)

    if launch and install:
        bid = cfg["bundle_id"]
        if not bid:
            parts.append("No bundle ID configured — skipping launch")
        else:
            ok, msg = await _launch_on_device(devicectl_uuid, bid)
            parts.append(msg)

    return "\n".join(parts)


@mcp.tool()
async def deploy_sim(
    workspace: str = Field(description="Absolute path to the .xcworkspace"),
    simulator: str = Field(description="Simulator UDID (use `simulator action=list` to find one)"),
    scheme: str | None = Field(default=None, description="Build scheme (default: from .env APP_SCHEME)"),
    bundle_id: str | None = Field(default=None, description="App bundle ID (default: auto-detected from built .app)"),
    skip_privacy: bool = Field(default=False, description="Skip auto-granting privacy permissions"),
) -> str:
    """Build, install, and launch the app with Pepper injected. Returns screen state."""
    # Build
    success, build_msg = await _build_app(workspace, scheme, simulator)
    if not success:
        return build_msg
    app_path = _find_built_app(workspace)

    # Deploy
    deploy_msg = await _deploy_app(
        simulator,
        send_fn=send_command,
        bundle_id=bundle_id,
        install_path=app_path,
        workspace=workspace,
        skip_privacy=skip_privacy,
    )
    return f"{build_msg}\n\n{deploy_msg}"


@mcp.tool()
async def webview(
    simulator: str | None = Field(default=None, description="Simulator UDID"),
    action: str = Field(default="url", description="Action: url, evaluate, dom"),
    script: str | None = Field(default=None, description="JavaScript to execute (for evaluate)"),
    selector: str | None = Field(default=None, description="CSS selector for DOM query (default: '*', for dom)"),
    index: int | None = Field(default=None, description="WKWebView index when multiple are present (default: 0)"),
    limit: int | None = Field(default=None, description="Max DOM elements to return (default: 50, for dom)"),
) -> str:
    """Inspect and interact with WKWebView instances — get URLs, execute JavaScript, or query the DOM."""
    params: dict = {"action": action}
    if script is not None:
        params["script"] = script
    if selector is not None:
        params["selector"] = selector
    if index is not None:
        params["index"] = index
    if limit is not None:
        params["limit"] = limit
    return await resolve_and_send_json(simulator, "webview", params, timeout=15)


def main():
    """Entry point for the pepper-mcp command."""
    import atexit

    def _cleanup_session():
        owned = pepper_sessions.my_session()
        if owned:
            pepper_sessions.release_simulator(owned)

    atexit.register(_cleanup_session)
    mcp.run(transport="stdio")


if __name__ == "__main__":
    main()

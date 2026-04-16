"""Script tool definitions for Pepper MCP.

Record, replay, and manage action sequences. Agents record flows they've
explored, then replay them in a single tool call to save tokens.
"""

from __future__ import annotations

import asyncio

from pydantic import Field

from .mcp_scripts import (
    delete_script,
    list_scripts,
    load_script,
    start_recording,
    stop_recording,
)
from .pepper_common import json_dumps, resolve_adapter_dir


def _resolve_adapter_config() -> dict:
    """Resolve adapter config from session context or .env."""
    from .mcp_build import get_session_context
    from .pepper_common import get_config
    ctx = get_session_context()
    adapter_type = ctx.get("adapter_type") or get_config().get("adapter_type")
    if adapter_type:
        adapter_dir = resolve_adapter_dir(adapter_type)
        if adapter_dir:
            import json
            import os
            config_path = os.path.join(adapter_dir, "config.json")
            try:
                with open(config_path) as f:
                    return json.load(f)
            except (OSError, json.JSONDecodeError):
                pass
    return {}


def register_script_tools(mcp, act_and_look_fn, resolve_and_send_fn, deploy_fn=None):
    """Register the script tool on the given MCP server.

    Args:
        mcp: FastMCP server instance.
        act_and_look_fn: async (simulator, cmd, params?, timeout?) -> list
        resolve_and_send_fn: async (simulator, cmd, params?, timeout?) -> str
        deploy_fn: async (workspace, simulator, scheme?, bundle_id?, skip_privacy?) -> str
    """

    @mcp.tool()
    async def script(
        action: str = Field(description="record, stop, run, list, show, or delete"),
        name: str | None = Field(default=None, description="Script name (required for record/run/show/delete)"),
        description: str | None = Field(default=None, description="Script description (for record)"),
        simulator: str | None = Field(default=None, description="Simulator UDID (required for record/stop/run)"),
        step_delay_ms: int | None = Field(default=None, description="Override inter-step delay during run (ms)"),
    ) -> str:
        """Record, replay, and manage action sequences.

        Record a flow you've already explored, then replay it in one call.
        Scripts save tokens by replacing multi-step sequences with a single tool call.

        Actions:
        - record: Start recording. Subsequent action tool calls are captured.
        - stop: Stop recording and save the script.
        - run: Replay a saved script. Returns final screen state.
        - list: Show available scripts for current app.
        - show: Display a script's steps.
        - delete: Remove a script.
        """
        # Resolve simulator from session affinity if not provided
        sim_key = simulator
        if not sim_key:
            from .mcp_build import get_session_context
            sim_key = get_session_context().get("simulator")
        if not sim_key and action in ("record", "stop", "run"):
            return "Error: simulator is required for record/stop/run. Pass it explicitly or deploy first."

        if action == "record":
            if not name:
                return "Error: name is required for record."
            return start_recording(name, description or "", sim_key)

        elif action == "stop":
            msg, _script = stop_recording(sim_key)
            return msg

        elif action == "run":
            if not name:
                return "Error: name is required for run."
            data = load_script(name)
            if not data:
                available = [s["name"] for s in list_scripts()]
                return f"Script '{name}' not found. Available: {available}"
            return await _replay(data, act_and_look_fn, simulator, step_delay_ms, deploy_fn)

        elif action == "list":
            scripts = list_scripts()
            if not scripts:
                return "No scripts available. Use script action=record to create one."
            lines = []
            for s in scripts:
                lines.append(f"  {s['name']} ({s['steps']} steps) — {s['description'] or 'no description'}")
            return "Available scripts:\n" + "\n".join(lines)

        elif action == "show":
            if not name:
                return "Error: name is required for show."
            data = load_script(name)
            if not data:
                return f"Script '{name}' not found."
            return json_dumps(data)

        elif action == "delete":
            if not name:
                return "Error: name is required for delete."
            return delete_script(name)

        else:
            return f"Unknown action '{action}'. Use: record, stop, run, list, show, delete."


async def _replay(
    script_data: dict,
    act_and_look_fn,
    simulator: str | None,
    step_delay_ms: int | None,
    deploy_fn=None,
) -> str:
    """Replay a script's steps and return a summary.

    Resilient to optional screens: when a tap/input step fails with
    "Element not found", checks if a later step's target exists on the
    current screen and skips ahead. This handles flows that vary
    (e.g. terms acceptance shown only on first launch).
    """
    steps = script_data.get("steps", [])
    if not steps:
        return "Script has no steps."

    results = []
    resp = None
    i = 0
    while i < len(steps):
        step = steps[i]
        tool = step.get("tool", "")
        params = step.get("params", {})
        wait_ms = step_delay_ms if step_delay_ms is not None else step.get("wait_ms", 300)

        try:
            # Deploy steps use the deploy function, not act_and_look
            if tool == "deploy":
                if not deploy_fn:
                    return (
                        f"Script '{script_data['name']}' has a deploy step but no deploy "
                        f"function is available."
                    )
                # Resolve deploy params: step params > adapter config > error
                adapter_cfg = _resolve_adapter_config()
                ws = params.get("workspace") or adapter_cfg.get("workspace", "")
                if ws:
                    import os
                    ws = os.path.expanduser(ws)
                if not ws:
                    return (
                        f"Script '{script_data['name']}' deploy step has no workspace. "
                        f"Set 'workspace' in adapter config.json or the step params."
                    )
                text = await deploy_fn(
                    workspace=ws,
                    simulator=simulator or params.get("simulator", ""),
                    scheme=params.get("scheme") or adapter_cfg.get("scheme"),
                    bundle_id=params.get("bundle_id") or adapter_cfg.get("bundle_id"),
                    skip_privacy=params.get("skip_privacy", False),
                )
                if "Error" in text[:50] or "failed" in text[:50].lower():
                    return (
                        f"Script '{script_data['name']}' failed at step {i + 1}/{len(steps)} "
                        f"(deploy):\n{text}"
                    )
                # Post-deploy health check: verify Pepper is alive before continuing
                if i < len(steps) - 1:
                    await asyncio.sleep(max(wait_ms / 1000, 2))  # At least 2s settle
                    try:
                        probe = await act_and_look_fn(simulator, "look", {})
                        probe_text = probe[-1].text if isinstance(probe, list) and probe else str(probe)
                        if _is_connection_error(probe_text):
                            return (
                                f"Script '{script_data['name']}' failed after deploy: "
                                f"Pepper not responding.\n{probe_text[:200]}"
                            )
                    except Exception as e:
                        return (
                            f"Script '{script_data['name']}' failed after deploy: "
                            f"health check error: {e}"
                        )
                results.append(f"  {i + 1}. deploy ✓")
                i += 1
                continue

            resp = await act_and_look_fn(simulator, tool, params)
            text = str(resp)

            # Connection failures: act_and_look returns JSON string on error
            if _is_connection_error(text):
                return (
                    f"Script '{script_data['name']}' failed at step {i + 1}/{len(steps)} "
                    f"({tool}): Pepper connection lost.\n{text[:200]}"
                )

            # Hard failures: always abort
            if "APP CRASHED" in text[:200]:
                return (
                    f"Script '{script_data['name']}' failed at step {i + 1}/{len(steps)} "
                    f"({tool}):\n{text}"
                )

            # Soft failure: element not found — try to skip optional steps
            if "Element not found" in text[:200]:
                skipped_to = _try_skip_ahead(text, steps, i)
                if skipped_to is not None:
                    for s in range(i, skipped_to):
                        results.append(f"  {s + 1}. {steps[s]['tool']} ⊘ (skipped)")
                    i = skipped_to
                    continue
                # Can't skip — real failure
                return (
                    f"Script '{script_data['name']}' failed at step {i + 1}/{len(steps)} "
                    f"({tool}):\n{text}"
                )

            # Other errors
            if "Error:" in text[:100] or '"status": "error"' in text[:100]:
                return (
                    f"Script '{script_data['name']}' failed at step {i + 1}/{len(steps)} "
                    f"({tool}):\n{text}"
                )

            results.append(f"  {i + 1}. {tool} ✓")
        except Exception as e:
            return (
                f"Script '{script_data['name']}' failed at step {i + 1}/{len(steps)} "
                f"({tool}): {e}"
            )

        # Wait between steps
        if i < len(steps) - 1 and wait_ms > 0:
            await asyncio.sleep(wait_ms / 1000)
        i += 1

    # Return summary with final screen state from last action
    summary = f"Script '{script_data['name']}' completed ({len(steps)} steps):\n"
    summary += "\n".join(results)
    if isinstance(resp, list) and resp:
        summary += f"\n\n--- Final screen state ---\n{resp[-1].text}"
    return summary


_CONNECTION_ERROR_PATTERNS = [
    "No Pepper instance",
    "Connection refused",
    "connect call failed",
    '"status": "error"',
    "not running",
]


def _is_connection_error(text: str) -> bool:
    """Check if response indicates Pepper is unreachable."""
    check = text[:300]
    return any(p in check for p in _CONNECTION_ERROR_PATTERNS)


def _try_skip_ahead(error_text: str, steps: list, current_idx: int) -> int | None:
    """When a step fails with 'Element not found', check if a later step's
    target exists on the current screen. Returns the index to skip to, or None."""
    # Extract the screen content from the error
    screen_text = error_text.lower()

    # Look at the next few steps to see if any target is on this screen
    for j in range(current_idx + 1, min(current_idx + 4, len(steps))):
        future_step = steps[j]
        future_params = future_step.get("params", {})
        # Check if the future step's text target is visible
        target = future_params.get("text", "")
        if target and target.lower() in screen_text:
            return j
    return None

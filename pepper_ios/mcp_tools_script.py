"""Script tool definitions for Pepper MCP.

Record, replay, and manage action sequences. Agents record flows they've
explored, then replay them in a single tool call to save tokens.
"""

from __future__ import annotations

import asyncio
import json

from pydantic import Field

from .mcp_scripts import (
    delete_script,
    list_scripts,
    load_script,
    start_recording,
    stop_recording,
)
from .pepper_common import json_dumps


def register_script_tools(mcp, act_and_look_fn, resolve_and_send_fn):
    """Register the script tool on the given MCP server.

    Args:
        mcp: FastMCP server instance.
        act_and_look_fn: async (simulator, cmd, params?, timeout?) -> list
        resolve_and_send_fn: async (simulator, cmd, params?, timeout?) -> str
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
            return await _replay(data, act_and_look_fn, simulator, step_delay_ms)

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
) -> str:
    """Replay a script's steps and return a summary."""
    steps = script_data.get("steps", [])
    if not steps:
        return "Script has no steps."

    results = []
    for i, step in enumerate(steps):
        tool = step.get("tool", "")
        params = step.get("params", {})
        wait_ms = step_delay_ms if step_delay_ms is not None else step.get("wait_ms", 300)

        try:
            resp = await act_and_look_fn(simulator, tool, params)
            # act_and_look returns list of TextContent or a string
            if isinstance(resp, list):
                text = resp[-1].text if resp else ""
            else:
                text = str(resp)

            # Check for errors
            if "Error:" in text[:50] or "APP CRASHED" in text[:50]:
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

    # Return summary with final screen state from last action
    summary = f"Script '{script_data['name']}' completed ({len(steps)} steps):\n"
    summary += "\n".join(results)
    if isinstance(resp, list) and resp:
        summary += f"\n\n--- Final screen state ---\n{resp[-1].text}"
    return summary

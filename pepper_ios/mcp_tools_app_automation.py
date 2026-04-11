"""Grouped app automation tool — script, wait_for, wait_idle, concurrency as subcommands."""

from __future__ import annotations

from pydantic import Field

from .pepper_commands import CMD_CONCURRENCY


def register_app_automation_tools(mcp, resolve_and_send, act_and_look_fn, deploy_fn=None):
    """Register the app_automation grouped tool.

    Args:
        mcp: FastMCP server instance.
        resolve_and_send: async (simulator, cmd, params?, timeout?) -> str (JSON)
        act_and_look_fn: async (simulator, cmd, params?, timeout?) -> list
        deploy_fn: async (workspace, simulator, ...) -> str (optional, for script replay)
    """

    @mcp.tool(name="app_automation")
    async def app_automation(
        command: str = Field(
            description="Subcommand: script | wait_for | wait_idle | concurrency"
        ),
        simulator: str | None = Field(default=None, description="Simulator UDID"),
        # script params
        action: str | None = Field(default=None, description="[script] record/stop/run/list/show/delete; [concurrency] summary/actors/tasks/cancel"),
        name: str | None = Field(default=None, description="[script] Script name"),
        description: str | None = Field(default=None, description="[script] Script description (for record)"),
        step_delay_ms: int | None = Field(default=None, description="[script] Override inter-step delay during run (ms)"),
        # wait_for params
        element: str | None = Field(default=None, description="[wait_for] Accessibility ID to wait for"),
        state: str | None = Field(default=None, description="[wait_for] State: visible (default), exists, has_value"),
        value: str | None = Field(default=None, description="[wait_for] Expected value (for has_value state)"),
        text: str | None = Field(default=None, description="[wait_for] Wait for text to appear"),
        screen: str | None = Field(default=None, description="[wait_for] Wait for specific screen ID"),
        predicate: str | None = Field(default=None, description="[wait_for] NSPredicate to match elements"),
        expect: str | None = Field(default=None, description="[wait_for] For predicate: match (default) or gone"),
        timeout_ms: int | None = Field(default=None, description="[wait_for/wait_idle] Timeout in milliseconds"),
        # wait_idle params
        include_network: bool = Field(default=False, description="[wait_idle] Also wait for pending network requests"),
        debug: bool = Field(default=False, description="[wait_idle] Return what's blocking idle instead of waiting"),
        # concurrency params
        pattern: str | None = Field(default=None, description="[concurrency] Filter actor classes by pattern"),
        address: str | None = Field(default=None, description="[concurrency] Task address to cancel (hex)"),
        limit: int | None = Field(default=None, description="[concurrency] Max results to return"),
    ) -> str:
        """Automation and concurrency tools. Subcommands:
        - script: Record, replay, and manage action sequences
        - wait_for: Wait for element visible, text appears, screen changes, or predicate match
        - wait_idle: Wait for app to become idle (no animations/transitions)
        - concurrency: Inspect Swift Concurrency runtime (tasks, actors, executor state)"""

        if command == "script":
            from .mcp_scripts import delete_script, list_scripts, load_script, start_recording, stop_recording
            from .pepper_common import json_dumps

            sim_key = simulator
            if not sim_key:
                from .mcp_build import get_session_context
                sim_key = get_session_context().get("simulator")
            if not sim_key and action in ("record", "stop", "run"):
                return "Error: simulator required for record/stop/run."

            act = action or "list"
            if act == "record":
                if not name:
                    return "Error: name required for record."
                return start_recording(name, description or "", sim_key)
            elif act == "stop":
                msg, _ = stop_recording(sim_key)
                return msg
            elif act == "run":
                if not name:
                    return "Error: name required for run."
                data = load_script(name)
                if not data:
                    available = [s["name"] for s in list_scripts()]
                    return f"Script '{name}' not found. Available: {available}"
                from .mcp_tools_script import _replay
                return await _replay(data, act_and_look_fn, simulator, step_delay_ms, deploy_fn)
            elif act == "list":
                scripts = list_scripts()
                if not scripts:
                    return "No scripts available."
                lines = [f"  {s['name']} ({s['steps']} steps) — {s['description'] or 'no description'}" for s in scripts]
                return "Available scripts:\n" + "\n".join(lines)
            elif act == "show":
                if not name:
                    return "Error: name required for show."
                data = load_script(name)
                return json_dumps(data) if data else f"Script '{name}' not found."
            elif act == "delete":
                if not name:
                    return "Error: name required for delete."
                return delete_script(name)
            return f"Unknown script action '{act}'."

        elif command == "wait_for":
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
            return await resolve_and_send(simulator, "wait_for", params, timeout=max(15, (timeout_ms or 5000) / 1000 + 2))

        elif command == "wait_idle":
            params = {}
            if timeout_ms is not None:
                params["timeout_ms"] = timeout_ms
            if include_network:
                params["include_network"] = True
            if debug:
                params["debug"] = True
            return await resolve_and_send(simulator, "wait_idle", params, timeout=max(10, (timeout_ms or 3000) / 1000 + 2))

        elif command == "concurrency":
            params = {"action": action or "summary"}
            if pattern:
                params["pattern"] = pattern
            if address:
                params["address"] = address
            if limit is not None:
                params["limit"] = limit
            return await resolve_and_send(simulator, CMD_CONCURRENCY, params)

        return f"Unknown command '{command}'. Use: script, wait_for, wait_idle, concurrency"

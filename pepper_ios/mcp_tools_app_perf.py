"""Grouped app performance tool — perf, animations, heap, hangs, renders, timers as subcommands."""

from __future__ import annotations

from pydantic import Field

from .pepper_commands import CMD_ANIMATIONS, CMD_HEAP, CMD_HEAP_SNAPSHOT, CMD_PERF, CMD_RENDERS, CMD_TIMERS


def register_app_perf_tools(mcp, resolve_and_send):
    """Register the app_perf grouped tool.

    Args:
        mcp: FastMCP server instance.
        resolve_and_send: async (simulator, cmd, params?, timeout?) -> str (JSON)
    """

    @mcp.tool(name="app_perf")
    async def app_perf(
        command: str = Field(
            description="Subcommand: perf | animations | heap | hangs | renders | timers"
        ),
        simulator: str | None = Field(default=None, description="Simulator UDID"),
        # perf params
        action: str | None = Field(default=None, description="[perf] fps/hitches/redraws; [heap] classes/controllers/find/inspect/read/baseline/check/diff/snapshot/snapshot_clear/snapshot_status; [hangs] start/stop/status/hangs/clear; [renders] start/stop/status/log/clear/counts/snapshot/diff/reset/ag_probe/ag_server/ag_dump/signpost/why; [timers] start/stop/list/invalidate/status/clear"),
        duration_ms: int | None = Field(default=None, description="[perf] Sampling duration in ms"),
        threshold_ms: int | None = Field(default=None, description="[perf/hangs] Threshold in ms"),
        # animations params
        point: str | None = Field(default=None, description="[animations] Coordinates 'x,y' to trace"),
        speed: float | None = Field(default=None, description="[animations] Animation speed multiplier (0=disabled, 0.1=slow-mo, 1=normal, 10=turbo)"),
        # heap params
        class_name: str | None = Field(default=None, description="[heap] Class name or pattern"),
        pattern: str | None = Field(default=None, description="[heap] Pattern for classes search"),
        key_path: str | None = Field(default=None, description="[heap] KVC key path to read (e.g. 'camera.zoom')"),
        min_growth: int | None = Field(default=None, description="[heap] Min instance growth to report in diff"),
        threshold: int | None = Field(default=None, description="[heap] Min instance growth to flag in check"),
        # renders params
        filter_text: str | None = Field(default=None, description="[renders/timers] Filter by name/pattern"),
        since_ms: int | None = Field(default=None, description="[renders] Only events after this epoch-ms"),
        name: str | None = Field(default=None, description="[renders] Snapshot name for ag_dump"),
        sub: str | None = Field(default=None, description="[renders] Sub-action for signpost: install or drain"),
        # timers params
        timer_id: str | None = Field(default=None, description="[timers] Timer/display-link ID to invalidate"),
        # shared
        limit: int | None = Field(default=None, description="Max results to return"),
        offset: int | None = Field(default=None, description="[heap] Skip this many results for pagination"),
    ) -> str:
        """Performance profiling tools. Subcommands:
        - perf: Measure frame rate, detect main-thread hitches, find expensive redraws
        - animations: Inspect running animations, trace movement, change animation speed
        - heap: Find live objects, inspect properties, detect memory leaks via baseline/check
        - hangs: Detect main thread hangs with symbolicated stack traces
        - renders: Track SwiftUI re-renders and diagnose excessive view body evaluations
        - timers: Track NSTimer and CADisplayLink instances, find leaked timers"""

        if command == "perf":
            params: dict = {"action": action or "fps"}
            if duration_ms is not None:
                params["duration_ms"] = duration_ms
            if threshold_ms is not None:
                params["threshold_ms"] = threshold_ms
            return await resolve_and_send(simulator, CMD_PERF, params, timeout=30)

        elif command == "animations":
            if action == "speed":
                params = {"action": "speed"}
                if speed is not None:
                    params["speed"] = speed
                return await resolve_and_send(simulator, CMD_ANIMATIONS, params)
            params = {}
            if action:
                params["action"] = action
            if point:
                params["point"] = point
            return await resolve_and_send(simulator, CMD_ANIMATIONS, params)

        elif command == "heap":
            act = action or "classes"
            snapshot_actions = {
                "snapshot": "snapshot", "diff": "diff", "snapshot_clear": "clear",
                "snapshot_status": "status", "baseline": "baseline", "check": "check",
            }
            if act in snapshot_actions:
                params = {"action": snapshot_actions[act]}
                if min_growth is not None:
                    params["min_growth"] = min_growth
                if threshold is not None:
                    params["threshold"] = threshold
                return await resolve_and_send(simulator, CMD_HEAP_SNAPSHOT, params)
            params = {"action": act}
            if class_name:
                params["class"] = class_name
            if pattern:
                params["pattern"] = pattern
            if key_path:
                params["key_path"] = key_path
            if limit is not None:
                params["limit"] = limit
            if offset is not None:
                params["offset"] = offset
            return await resolve_and_send(simulator, CMD_HEAP, params)

        elif command == "hangs":
            params = {"action": action or "status"}
            if threshold_ms is not None:
                params["threshold_ms"] = threshold_ms
            if limit is not None:
                params["limit"] = limit
            return await resolve_and_send(simulator, "hangs", params, timeout=15)

        elif command == "renders":
            if not action:
                return "Error: action required for renders (start, stop, status, log, clear, counts, snapshot, diff, reset, ag_probe, ag_server, ag_dump, signpost, why)"
            params = {"action": action}
            if limit is not None:
                params["limit"] = limit
            if since_ms is not None:
                params["since_ms"] = since_ms
            if filter_text is not None:
                params["filter"] = filter_text
            if name is not None:
                params["name"] = name
            if sub is not None:
                params["sub"] = sub
            return await resolve_and_send(simulator, CMD_RENDERS, params)

        elif command == "timers":
            params = {"action": action or "list"}
            if timer_id:
                params["id"] = timer_id
            if filter_text:
                params["filter"] = filter_text
            if limit is not None:
                params["limit"] = limit
            return await resolve_and_send(simulator, CMD_TIMERS, params)

        return f"Unknown command '{command}'. Use: perf, animations, heap, hangs, renders, timers"

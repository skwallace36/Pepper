"""Performance and profiling tool definitions for Pepper MCP.

Tool definitions for: perf, animations, heap.
"""

from __future__ import annotations

from pydantic import Field

from .pepper_commands import CMD_ANIMATIONS, CMD_HEAP, CMD_HEAP_SNAPSHOT, CMD_PERF


def register_perf_tools(mcp, resolve_and_send):
    """Register performance and profiling tools on the given MCP server.

    Args:
        mcp: FastMCP server instance.
        resolve_and_send: async (simulator, cmd, params?, timeout?) -> dict
    """

    @mcp.tool()
    async def perf(
        simulator: str | None = Field(default=None, description="Simulator UDID"),
        action: str = Field(default="fps", description="Action: fps, hitches, redraws"),
        duration_ms: int | None = Field(
            default=None, description="Sampling duration in ms (for fps/hitches; default: 2000/5000)"
        ),
        threshold_ms: int | None = Field(
            default=None, description="Hitch threshold in ms (for hitches action; default: 16)"
        ),
    ) -> str:
        """Measure frame rate (fps), detect main-thread hitches, or find expensive redraws in the layer tree."""
        params: dict = {"action": action}
        if duration_ms is not None:
            params["duration_ms"] = duration_ms
        if threshold_ms is not None:
            params["threshold_ms"] = threshold_ms
        return await resolve_and_send(simulator, CMD_PERF, params, timeout=30)

    @mcp.tool()
    async def animations(
        simulator: str | None = Field(default=None, description="Simulator UDID"),
        action: str | None = Field(default=None, description="Action: scan (default), trace, or speed"),
        point: str | None = Field(default=None, description="Coordinates 'x,y' to trace (for trace action)"),
        speed: float | None = Field(
            default=None,
            description="Animation speed multiplier for action=speed: 0=disabled, 0.1=slow-mo, 1=normal, 10=turbo",
        ),
    ) -> str:
        """Inspect running animations (scan), trace view movement, or change global animation speed."""
        if action == "speed":
            params: dict = {"action": "speed"}
            if speed is not None:
                params["speed"] = speed
            return await resolve_and_send(simulator, CMD_ANIMATIONS, params)
        params = {}
        if action:
            params["action"] = action
        if point:
            params["point"] = point
        return await resolve_and_send(simulator, CMD_ANIMATIONS, params)

    @mcp.tool()
    async def heap(
        simulator: str | None = Field(default=None, description="Simulator UDID"),
        action: str = Field(
            description="Action: classes | controllers | find | inspect | read | baseline | check | diff | snapshot | snapshot_clear | snapshot_status"
        ),
        class_name: str | None = Field(default=None, description="Class name or pattern to search for"),
        pattern: str | None = Field(default=None, description="Pattern for classes search"),
        key_path: str | None = Field(
            default=None, description="KVC key path to read (for 'read' action, e.g. 'camera.zoom')"
        ),
        limit: int | None = Field(default=None, description="Max results to return (default: 20 for classes/controllers)"),
        offset: int | None = Field(default=None, description="Skip this many results for pagination (default: 0)"),
        min_growth: int | None = Field(default=None, description="Min instance growth to report in diff (default: 1)"),
        threshold: int | None = Field(default=None, description="Min instance growth to flag in check (default: 1)"),
    ) -> str:
        """Find live objects on the heap, inspect their properties, and detect memory leaks via baseline/check diffing."""
        # Route snapshot/diff/baseline/check actions to the heap_snapshot handler
        snapshot_actions = {
            "snapshot": "snapshot",
            "diff": "diff",
            "snapshot_clear": "clear",
            "snapshot_status": "status",
            "baseline": "baseline",
            "check": "check",
        }
        if action in snapshot_actions:
            params: dict = {"action": snapshot_actions[action]}
            if min_growth is not None:
                params["min_growth"] = min_growth
            if threshold is not None:
                params["threshold"] = threshold
            return await resolve_and_send(simulator, CMD_HEAP_SNAPSHOT, params)
        params = {"action": action}
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

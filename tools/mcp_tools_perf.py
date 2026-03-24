"""Performance and profiling tool definitions for Pepper MCP.

Tool definitions for: perf, animations, heap.
"""
from __future__ import annotations

from pydantic import Field


def register_perf_tools(mcp, resolve_and_send):
    """Register performance and profiling tools on the given MCP server.

    Args:
        mcp: FastMCP server instance.
        resolve_and_send: async (simulator, cmd, params?, timeout?) -> str
    """

    @mcp.tool()
    async def perf(
        simulator: str | None = Field(default=None, description="Simulator UDID"),
        action: str = Field(default="fps", description="Action: fps, hitches, redraws"),
        duration_ms: int | None = Field(default=None, description="Sampling duration in ms (for fps/hitches; default: 2000/5000)"),
        threshold_ms: int | None = Field(default=None, description="Hitch threshold in ms (for hitches action; default: 16)"),
    ) -> str:
        """Performance diagnostics: FPS measurement, main-thread hitch detection, expensive redraw identification.

        action=fps: measure frame rate using CADisplayLink. Returns avg/min/max FPS, dropped frames, per-second buckets.
        action=hitches: detect main-thread blocks via background watchdog. Returns hitch count, durations, and timestamps.
        action=redraws: scan the layer tree for expensive rendering: shadows without shadowPath, masks, rasterization,
        oversized images, semi-transparent large layers. Returns issues sorted by severity."""
        params: dict = {"action": action}
        if duration_ms is not None:
            params["duration_ms"] = duration_ms
        if threshold_ms is not None:
            params["threshold_ms"] = threshold_ms
        return await resolve_and_send(simulator, "perf", params, timeout=30)

    @mcp.tool()
    async def animations(
        simulator: str | None = Field(default=None, description="Simulator UDID"),
        action: str | None = Field(default=None, description="Action: scan (default), trace, or speed"),
        point: str | None = Field(default=None, description="Coordinates 'x,y' to trace (for trace action)"),
        speed: float | None = Field(default=None, description="Animation speed multiplier for action=speed: 0=disabled, 0.1=slow-mo, 1=normal, 10=turbo"),
    ) -> str:
        """Scan active animations, trace view movement, or control animation speed.
        action=scan: find all active CAAnimations. action=trace: sample a view's position over time.
        action=speed: set global animation speed (0=off, 1=normal, 10=turbo). Omit speed to query current."""
        if action == "speed":
            params: dict = {"action": "speed"}
            if speed is not None:
                params["speed"] = speed
            return await resolve_and_send(simulator, "animations", params)
        params = {}
        if action:
            params["action"] = action
        if point:
            params["point"] = point
        return await resolve_and_send(simulator, "animations", params)

    @mcp.tool()
    async def heap(
        simulator: str | None = Field(default=None, description="Simulator UDID"),
        action: str = Field(description="Action: classes, controllers, find, inspect, read, snapshot, diff, baseline, check, snapshot_clear, snapshot_status"),
        class_name: str | None = Field(default=None, description="Class name or pattern to search for"),
        pattern: str | None = Field(default=None, description="Pattern for classes search"),
        key_path: str | None = Field(default=None, description="KVC key path to read (for 'read' action, e.g. 'camera.zoom')"),
        limit: int | None = Field(default=None, description="Max results to return"),
        min_growth: int | None = Field(default=None, description="Min instance growth to report in diff (default: 1)"),
        threshold: int | None = Field(default=None, description="Min instance growth to flag in check (default: 1)"),
    ) -> str:
        """Find live objects, inspect state, and detect memory leaks.

        Discovery actions:
        - classes: search loaded ObjC classes by pattern (e.g. 'Manager', 'Service', 'MapView')
        - controllers: list all live UIViewControllers (with hierarchy)
        - find: locate a singleton instance (tries .shared, .default, .current, etc.)

        Inspection actions:
        - inspect: full property dump of a found instance (all ObjC properties)
        - read: read a specific property via KVC key path. Supports nested paths
          (e.g. class_name='GMSMapView', key_path='camera.zoom'). Read-only — cannot set values.

        Leak detection actions:
        - baseline: capture current instance counts as a reference baseline
        - check: compare current counts to baseline, flag growing classes with severity levels
          (high/medium/low). Returns structured { leaks: [{class, baseline, current, delta, severity}] }
          suitable for automated test assertions.
        - snapshot: alias for baseline (save current counts)
        - diff: compare current counts to baseline — growing counts indicate retain cycles
        - snapshot_clear / snapshot_status: manage the saved baseline

        Leak detection workflow: baseline → navigate to a screen and back 3x → check.
        Automated test workflow: baseline → exercise feature → check (assert leak_count == 0).

        Related tools: vars_inspect (ViewModel @Published properties — read AND write),
        defaults (UserDefaults — persistent config), layers (CALayer visual properties)."""
        # Route snapshot/diff/baseline/check actions to the heap_snapshot handler
        snapshot_actions = {"snapshot": "snapshot", "diff": "diff",
                            "snapshot_clear": "clear", "snapshot_status": "status",
                            "baseline": "baseline", "check": "check"}
        if action in snapshot_actions:
            params: dict = {"action": snapshot_actions[action]}
            if min_growth is not None:
                params["min_growth"] = min_growth
            if threshold is not None:
                params["threshold"] = threshold
            return await resolve_and_send(simulator, "heap_snapshot", params)
        params = {"action": action}
        if class_name:
            params["class"] = class_name
        if pattern:
            params["pattern"] = pattern
        if key_path:
            params["key_path"] = key_path
        if limit is not None:
            params["limit"] = limit
        return await resolve_and_send(simulator, "heap", params)

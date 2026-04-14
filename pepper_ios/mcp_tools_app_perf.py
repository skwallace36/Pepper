"""Grouped app performance tool — perf, animations, heap, hangs, renders, timers as subcommands."""

from __future__ import annotations

from pydantic import Field

from .pepper_commands import CMD_ANIMATIONS, CMD_HEAP, CMD_HEAP_SNAPSHOT, CMD_PERF, CMD_RENDERS, CMD_TIMERS


def register_app_perf_tools(mcp, resolve_and_send):
    """Register the app_perf grouped tool."""

    @mcp.tool(name="app_perf")
    async def app_perf(
        command: str = Field(description="Subcommand: perf | animations | heap | hangs | renders | timers | profile"),
        simulator: str | None = Field(default=None, description="Simulator UDID"),
        action: str | None = Field(default=None, description="Action for the subcommand"),
        duration_ms: int | None = Field(default=None, description="Sampling duration in ms (perf)"),
        threshold_ms: int | None = Field(default=None, description="Threshold in ms (perf/hangs)"),
        point: str | None = Field(default=None, description="Coordinates 'x,y' to trace (animations)"),
        speed: float | None = Field(default=None, description="Animation speed multiplier: 0=disabled, 0.1=slow-mo, 1=normal (animations)"),
        class_name: str | None = Field(default=None, description="Class name or pattern (heap)"),
        pattern: str | None = Field(default=None, description="Pattern for classes search (heap)"),
        key_path: str | None = Field(default=None, description="KVC key path to read, e.g. 'camera.zoom' (heap)"),
        min_growth: int | None = Field(default=None, description="Min instance growth to report in diff (heap)"),
        threshold: int | None = Field(default=None, description="Min instance growth to flag in check (heap)"),
        filter_text: str | None = Field(default=None, description="Filter by name/pattern (renders/timers)"),
        since_ms: int | None = Field(default=None, description="Only events after this epoch-ms (renders)"),
        name: str | None = Field(default=None, description="Snapshot name for ag_dump (renders)"),
        sub: str | None = Field(default=None, description="Sub-action for signpost: install or drain (renders)"),
        timer_id: str | None = Field(default=None, description="Timer/display-link ID to invalidate (timers)"),
        limit: int | None = Field(default=None, description="Max results to return"),
        offset: int | None = Field(default=None, description="Skip results for pagination (heap)"),
        interval_us: int | None = Field(default=None, description="Sampling interval in microseconds, default 1000 (profile)"),
    ) -> str:
        """Performance profiling tools.

Subcommands:
- perf: Measure frame rate, detect hitches, find expensive redraws. Actions: fps, hitches, redraws
- animations: Inspect running animations, trace movement, change speed. Actions: scan, trace, speed
- heap: Find live objects, inspect properties, detect leaks. Actions: classes, controllers, find, inspect, read, baseline, check, diff, snapshot
- hangs: Detect main thread hangs with stack traces. Actions: start, stop, status, hangs, clear
- renders: Track SwiftUI re-renders. Actions: start, stop, status, log, clear, counts, snapshot, diff, reset
- timers: Track NSTimer/CADisplayLink instances. Actions: start, stop, list, invalidate, status, clear
- profile: Sampling profiler — captures main thread stacks at 1ms intervals. Actions: start, stop, status. Start profiling, use the app, stop to get top functions and hot paths."""

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
                return "Error: action required. Use: start, stop, status, log, clear, counts, snapshot, diff, reset"
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

        elif command == "profile":
            params = {"action": action or "status"}
            if interval_us is not None:
                params["interval_us"] = interval_us
            return await resolve_and_send(simulator, "profile", params, timeout=30)

        return f"Error: unknown command '{command}'. Use: perf, animations, heap, hangs, renders, timers, profile"

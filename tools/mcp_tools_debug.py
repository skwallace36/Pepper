"""Debug and introspection tool definitions for Pepper MCP.

Tool definitions for: layers, console, crash_log, lifecycle, responder_chain,
notifications, constraints, timers, concurrency.
"""
from __future__ import annotations

import json
import os
import time

from mcp_crash import parse_crash_report
from pepper_common import get_config
from pydantic import Field


def register_debug_tools(mcp, resolve_and_send):
    """Register debug/introspection tools on the given MCP server.

    Args:
        mcp: FastMCP server instance.
        resolve_and_send: async (simulator, cmd, params?, timeout?) -> str
    """

    @mcp.tool()
    async def layers(
        simulator: str | None = Field(default=None, description="Simulator UDID"),
        point: str = Field(description="Screen coordinates 'x,y' to inspect"),
        depth: int | None = Field(default=None, description="Max layer tree depth"),
    ) -> str:
        """Inspect the CALayer tree at a screen point. Returns colors, gradients, shadows, transforms."""
        params: dict = {"point": point}
        if depth is not None:
            params["depth"] = depth
        return await resolve_and_send(simulator, "layers", params)

    @mcp.tool()
    async def console(
        simulator: str | None = Field(default=None, description="Simulator UDID"),
        action: str = Field(description="Action: start, stop, log"),
        filter_text: str | None = Field(default=None, description="Filter log lines (for log action)"),
        limit: int | None = Field(default=None, description="Max lines to return (for log action)"),
    ) -> str:
        """Capture and read app logs — both print() (stdout) and NSLog (stderr). Start capture first, then check logs."""
        params: dict = {"action": action}
        if filter_text:
            params["filter"] = filter_text
        if limit is not None:
            params["limit"] = limit
        return await resolve_and_send(simulator, "console", params)

    @mcp.tool()
    async def crash_log(
        simulator: str | None = Field(default=None, description="Simulator UDID"),
        last_n: int = Field(default=1, description="Number of recent crash reports to show (default: 1, max: 5)"),
        seconds: int = Field(default=300, description="Look back this many seconds (default: 300 = 5 minutes)"),
    ) -> str:
        """Fetch recent crash reports for the app. Parses .ips files from DiagnosticReports.
        Shows exception type, reason, and crashed thread stack trace.
        Automatically called when APP CRASHED is detected — use this for on-demand access
        or to look further back in time."""
        cfg = get_config()
        bundle_id = cfg.get("bundle_id", "")
        reports_dir = os.path.expanduser("~/Library/Logs/DiagnosticReports")

        if not os.path.isdir(reports_dir):
            return "No DiagnosticReports directory found."

        cutoff = time.time() - seconds
        last_n = min(last_n, 5)
        candidates = []
        try:
            for entry in os.scandir(reports_dir):
                if entry.name.endswith(".ips"):
                    try:
                        mtime = entry.stat().st_mtime
                        if mtime >= cutoff:
                            candidates.append((mtime, entry.path))
                    except OSError:
                        pass
        except OSError:
            return "Failed to read DiagnosticReports directory."

        if not candidates:
            return f"No crash reports found in the last {seconds}s."

        candidates.sort(reverse=True)

        # Filter by bundle ID if we have one
        results = []
        for _, path in candidates:
            if len(results) >= last_n:
                break
            try:
                with open(path) as f:
                    content = f.read()
                if bundle_id and bundle_id not in content:
                    continue
                parsed = parse_crash_report(path, content)
                if parsed:
                    results.append(parsed)
            except OSError:
                continue

        if not results:
            return f"No crash reports matching {bundle_id} in the last {seconds}s. Found {len(candidates)} total .ips files."

        return "\n".join(results)

    @mcp.tool()
    async def lifecycle(
        simulator: str | None = Field(default=None, description="Simulator UDID"),
        action: str = Field(description="Action: background, foreground, memory_warning"),
    ) -> str:
        """Trigger app lifecycle events (background/foreground/memory warning)."""
        return await resolve_and_send(simulator, "lifecycle", {"action": action})

    @mcp.tool()
    async def responder_chain(
        simulator: str | None = Field(default=None, description="Simulator UDID"),
        point: str | None = Field(default=None, description="Screen coordinates 'x,y' to inspect"),
        element: str | None = Field(default=None, description="Accessibility identifier of the element"),
        text: str | None = Field(default=None, description="Text label of the element"),
    ) -> str:
        """Dump gesture recognizers, responder chain, and hit-test path for a point or element.
        Shows every gesture recognizer on the view and its ancestors, the full UIResponder chain,
        and the hit-test traversal path. Useful for debugging why taps or gestures aren't being received."""
        params: dict = {}
        if point:
            parts = point.split(",")
            if len(parts) == 2:
                params["point"] = {"x": float(parts[0]), "y": float(parts[1])}
        if element:
            params["element"] = element
        if text:
            params["text"] = text
        return await resolve_and_send(simulator, "responder_chain", params)

    @mcp.tool()
    async def notifications(
        simulator: str | None = Field(default=None, description="Simulator UDID"),
        action: str = Field(description="Action: start, stop, list, counts, post, events, status, clear"),
        name: str | None = Field(default=None, description="Notification name to post (for 'post' action)"),
        filter_text: str | None = Field(default=None, description="Filter observers/events by notification name or class pattern"),
        user_info: str | None = Field(default=None, description="JSON string of userInfo dict to include when posting (for 'post' action)"),
        limit: int | None = Field(default=None, description="Max results to return (for list/events actions)"),
    ) -> str:
        """Inspect NSNotificationCenter observers and post arbitrary notifications.

        Start tracking first, then list/count observers. Useful for debugging
        'why didn't my view update?' — see what's observing what, detect leaked
        observers (growing counts), and trigger behavior by posting test notifications.

        Workflow: start → use the app → list/counts to see registrations → post to test.

        Actions:
        - start: begin tracking observer add/remove (installs swizzles)
        - stop: stop tracking
        - list: show tracked observers, optionally filtered by name/class pattern
        - counts: observer counts grouped by notification name (detect leaks)
        - post: fire a notification (provide name, optional user_info as JSON)
        - events: chronological add/remove history
        - status: check if tracking is active
        - clear: reset all tracked data"""
        params = {"action": action}
        if name:
            params["name"] = name
        if filter_text:
            params["filter"] = filter_text
        if user_info:
            try:
                params["user_info"] = json.loads(user_info)
            except json.JSONDecodeError:
                return "Error: user_info must be valid JSON"
        if limit is not None:
            params["limit"] = limit
        return await resolve_and_send(simulator, "notifications", params)

    @mcp.tool()
    async def constraints(
        simulator: str | None = Field(default=None, description="Simulator UDID"),
        element: str | None = Field(default=None, description="Accessibility ID to scope to a subtree"),
        ambiguous_only: bool = Field(default=False, description="Only return views with ambiguous layout"),
        depth: int | None = Field(default=None, description="Max recursion depth (default: 30)"),
    ) -> str:
        """Dump AutoLayout constraints with ambiguity detection (like Chisel paltrace).

        Walks the view hierarchy and returns every NSLayoutConstraint with its attributes,
        relation, constant, multiplier, and priority. Views with ambiguous layout are flagged
        and include the private _autolayoutTrace output for debugging.

        Use ambiguous_only=true to quickly find layout issues without scanning the full tree."""
        params: dict = {}
        if element:
            params["element"] = element
        if ambiguous_only:
            params["ambiguous_only"] = True
        if depth is not None:
            params["depth"] = depth
        return await resolve_and_send(simulator, "constraints", params)

    @mcp.tool()
    async def timers(
        simulator: str | None = Field(default=None, description="Simulator UDID"),
        action: str = Field(default="list", description="Action: start, stop, list, invalidate, status, clear"),
        timer_id: str | None = Field(default=None, description="Timer/display-link ID to invalidate (e.g. timer_3, dlink_1)"),
        filter_text: str | None = Field(default=None, description="Filter by target class or selector name"),
        limit: int | None = Field(default=None, description="Max results to return (default 100)"),
    ) -> str:
        """Discover and inspect active NSTimer and CADisplayLink instances.

        Finds leaked timers, unnecessary background work, and battery-draining activity.
        Call start first to install tracking, then list to see active timers.

        Workflow: start → use the app → list to see timers/display links → invalidate to test.

        Actions:
        - start: begin tracking timer/display-link creation (installs swizzles)
        - stop: stop tracking
        - list: show all tracked active timers and display links
        - invalidate: cancel a timer/display-link by ID (for testing)
        - status: check if tracking is active and current counts
        - clear: reset all tracked data

        Each timer shows: interval, target class, selector, repeat flag, fire date.
        Each display link shows: target class, selector, preferred FPS, paused state.
        DispatchSourceTimer tracking is not supported (C-level dispatch objects)."""
        params: dict = {"action": action}
        if timer_id:
            params["id"] = timer_id
        if filter_text:
            params["filter"] = filter_text
        if limit is not None:
            params["limit"] = limit
        return await resolve_and_send(simulator, "timers", params)

    @mcp.tool()
    async def concurrency(
        simulator: str | None = Field(default=None, description="Simulator UDID"),
        action: str = Field(
            default="summary",
            description="Action: summary, actors, tasks, cancel",
        ),
        pattern: str | None = Field(
            default=None,
            description="Filter actor classes by name pattern (for 'actors' action)",
        ),
        address: str | None = Field(
            default=None,
            description="Task address to cancel, hex string e.g. '0x1234abcd' (for 'cancel' action)",
        ),
        limit: int | None = Field(
            default=None, description="Max results to return"
        ),
    ) -> str:
        """Inspect the Swift Concurrency runtime: active Tasks, actor classes, and executor state.

        Actions:
        - summary: overview of concurrency state — active task count, actor classes, MainActor status
        - actors: list all actor classes found in the runtime, with singleton instance discovery
        - tasks: active task count and current task context details (priority, flags, cancellation)
        - cancel: cancel a task by address (cooperative — task must check for cancellation)

        Useful for debugging: deadlocked actors, priority inversions, runaway tasks,
        and understanding the concurrency topology of a running app."""
        params: dict = {"action": action}
        if pattern:
            params["pattern"] = pattern
        if address:
            params["address"] = address
        if limit is not None:
            params["limit"] = limit
        return await resolve_and_send(simulator, "concurrency", params)

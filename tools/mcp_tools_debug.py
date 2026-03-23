"""Debug and introspection tool definitions for Pepper MCP.

Tool definitions for: layers, console, network, timeline, crash_log,
animations, lifecycle, heap, responder_chain.
"""

import os
import time
from typing import Optional

from pydantic import Field

from mcp_crash import parse_crash_report
from pepper_common import get_config


def register_debug_tools(mcp, resolve_and_send):
    """Register debug/introspection tools on the given MCP server.

    Args:
        mcp: FastMCP server instance.
        resolve_and_send: async (simulator, cmd, params?, timeout?) -> str
    """

    @mcp.tool()
    async def layers(
        simulator: Optional[str] = Field(default=None, description="Simulator UDID"),
        point: str = Field(description="Screen coordinates 'x,y' to inspect"),
        depth: Optional[int] = Field(default=None, description="Max layer tree depth"),
    ) -> str:
        """Inspect the CALayer tree at a screen point. Returns colors, gradients, shadows, transforms."""
        params = {"point": point}
        if depth is not None:
            params["depth"] = depth
        return await resolve_and_send(simulator, "layers", params)

    @mcp.tool()
    async def console(
        simulator: Optional[str] = Field(default=None, description="Simulator UDID"),
        action: str = Field(description="Action: start, stop, log"),
        filter_text: Optional[str] = Field(default=None, description="Filter log lines (for log action)"),
        limit: Optional[int] = Field(default=None, description="Max lines to return (for log action)"),
    ) -> str:
        """Capture and read app logs — both print() (stdout) and NSLog (stderr). Start capture first, then check logs."""
        params = {"action": action}
        if filter_text:
            params["filter"] = filter_text
        if limit is not None:
            params["limit"] = limit
        return await resolve_and_send(simulator, "console", params)

    @mcp.tool()
    async def network(
        simulator: Optional[str] = Field(default=None, description="Simulator UDID"),
        action: str = Field(description="Action: start, stop, log"),
        filter_text: Optional[str] = Field(default=None, description="Filter by URL pattern (for log action)"),
        limit: Optional[int] = Field(default=None, description="Max entries to return (for log action)"),
        max_body: Optional[int] = Field(default=None, description="Max chars per request/response body (default: 4096). Use 0 for unlimited."),
    ) -> str:
        """Monitor HTTP network traffic — see every API call, status code, and response body. Use this to check if data is loading instead of adding print statements."""
        params = {"action": action}
        if filter_text:
            params["filter"] = filter_text
        if limit is not None:
            params["limit"] = limit
        if max_body is not None:
            params["max_body"] = max_body
        return await resolve_and_send(simulator, "network", params)

    @mcp.tool()
    async def timeline(
        simulator: Optional[str] = Field(default=None, description="Simulator UDID"),
        action: str = Field(default="query", description="Action: query, status, config, clear"),
        limit: Optional[int] = Field(default=None, description="Max events to return (default 100)"),
        types: Optional[str] = Field(default=None, description="Comma-separated event types: network, console, screen, command"),
        last_seconds: Optional[int] = Field(default=None, description="Events from the last N seconds (convenience for since_ms)"),
        since_ms: Optional[int] = Field(default=None, description="Only events after this epoch ms timestamp"),
        filter_text: Optional[str] = Field(default=None, description="Filter events by summary substring"),
        buffer_size: Optional[int] = Field(default=None, description="Set buffer size (for config action)"),
        recording: Optional[bool] = Field(default=None, description="Enable/disable recording (for config action)"),
    ) -> str:
        """Always-on flight recorder timeline. Captures network requests, console logs, screen transitions,
        and command dispatch into a ring buffer — no setup needed. Query to correlate events when debugging."""
        params = {"action": action}
        if limit is not None:
            params["limit"] = limit
        if types:
            params["types"] = types.split(",")
        if last_seconds is not None:
            params["since_ms"] = int(time.time() * 1000) - last_seconds * 1000
        elif since_ms is not None:
            params["since_ms"] = since_ms
        if filter_text:
            params["filter"] = filter_text
        if buffer_size is not None:
            params["buffer_size"] = buffer_size
        if recording is not None:
            params["recording"] = recording
        return await resolve_and_send(simulator, "timeline", params)

    @mcp.tool()
    async def crash_log(
        simulator: Optional[str] = Field(default=None, description="Simulator UDID"),
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
    async def animations(
        simulator: Optional[str] = Field(default=None, description="Simulator UDID"),
        action: Optional[str] = Field(default=None, description="Action: scan (default), trace, or speed"),
        point: Optional[str] = Field(default=None, description="Coordinates 'x,y' to trace (for trace action)"),
        speed: Optional[float] = Field(default=None, description="Animation speed multiplier for action=speed: 0=disabled, 0.1=slow-mo, 1=normal, 10=turbo"),
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
    async def lifecycle(
        simulator: Optional[str] = Field(default=None, description="Simulator UDID"),
        action: str = Field(description="Action: background, foreground, memory_warning"),
    ) -> str:
        """Trigger app lifecycle events (background/foreground/memory warning)."""
        return await resolve_and_send(simulator, "lifecycle", {"action": action})

    @mcp.tool()
    async def heap(
        simulator: Optional[str] = Field(default=None, description="Simulator UDID"),
        action: str = Field(description="Action: classes, controllers, find, inspect, read, snapshot, diff, snapshot_clear, snapshot_status"),
        class_name: Optional[str] = Field(default=None, description="Class name or pattern to search for"),
        pattern: Optional[str] = Field(default=None, description="Pattern for classes search"),
        key_path: Optional[str] = Field(default=None, description="KVC key path to read (for 'read' action, e.g. 'camera.zoom')"),
        limit: Optional[int] = Field(default=None, description="Max results to return"),
        min_growth: Optional[int] = Field(default=None, description="Min instance growth to report in diff (default: 1)"),
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
        - snapshot: save current VC instance counts as baseline
        - diff: compare current counts to baseline — growing counts indicate retain cycles
        - snapshot_clear / snapshot_status: manage the saved baseline

        Leak detection workflow: snapshot → navigate to a screen and back 3x → diff.

        Related tools: vars_inspect (ViewModel @Published properties — read AND write),
        defaults (UserDefaults — persistent config), layers (CALayer visual properties)."""
        # Route snapshot/diff actions to the heap_snapshot handler
        snapshot_actions = {"snapshot": "snapshot", "diff": "diff",
                            "snapshot_clear": "clear", "snapshot_status": "status"}
        if action in snapshot_actions:
            params: dict = {"action": snapshot_actions[action]}
            if min_growth is not None:
                params["min_growth"] = min_growth
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

    @mcp.tool()
    async def responder_chain(
        simulator: Optional[str] = Field(default=None, description="Simulator UDID"),
        point: Optional[str] = Field(default=None, description="Screen coordinates 'x,y' to inspect"),
        element: Optional[str] = Field(default=None, description="Accessibility identifier of the element"),
        text: Optional[str] = Field(default=None, description="Text label of the element"),
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

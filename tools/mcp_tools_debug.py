"""Debug and introspection tool definitions for Pepper MCP.

Tool definitions for: layers, console, network, timeline, crash_log,
animations, lifecycle, heap, responder_chain, notifications, timers, perf.
"""

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
    async def network(
        simulator: str | None = Field(default=None, description="Simulator UDID"),
        action: str = Field(description="Action: start, stop, log, status, clear, simulate, conditions, remove_condition, clear_conditions, mock, mocks, remove_mock, clear_mocks"),
        filter_text: str | None = Field(default=None, description="Filter by URL pattern (for log action)"),
        limit: int | None = Field(default=None, description="Max entries to return (for log action)"),
        max_body: int | None = Field(default=None, description="Max chars per request/response body (default: 4096). Use 0 for unlimited."),
        effect: str | None = Field(default=None, description="Condition effect for simulate: latency, fail_status, fail_error, throttle, offline"),
        latency_ms: int | None = Field(default=None, description="Latency in ms (for effect=latency)"),
        status_code: int | None = Field(default=None, description="HTTP status code (for effect=fail_status)"),
        error_domain: str | None = Field(default=None, description="NSError domain (for effect=fail_error, default: NSURLErrorDomain)"),
        error_code: int | None = Field(default=None, description="NSError code (for effect=fail_error)"),
        bytes_per_second: int | None = Field(default=None, description="Bandwidth limit in bytes/sec (for effect=throttle)"),
        url: str | None = Field(default=None, description="URL pattern to match (for simulate/mock — substring, case-insensitive)"),
        method: str | None = Field(default=None, description="HTTP method to match (for simulate/mock — e.g., GET, POST)"),
        condition_id: str | None = Field(default=None, description="Condition ID (for remove_condition, or custom ID for simulate)"),
        mock_status: int | None = Field(default=None, description="HTTP status code for mock response (default: 200)"),
        mock_body: str | None = Field(default=None, description="Response body for mock (JSON string)"),
        mock_id: str | None = Field(default=None, description="Mock ID (for remove_mock, or custom ID for mock)"),
    ) -> str:
        """Monitor HTTP network traffic, simulate network conditions, and mock API responses.

        Monitoring: start/stop/log/status/clear — see every API call, status code, and response body.

        Simulation: simulate adverse conditions without external tools:
        - latency: add delay (ms) to matching requests
        - fail_status: return synthetic HTTP error (e.g., 500, 503)
        - fail_error: return NSError (e.g., NSURLErrorNotConnectedToInternet)
        - throttle: limit bandwidth (bytes/sec) for matching requests
        - offline: fail all matching requests as if no network

        Mocking: intercept requests and return stubbed responses without hitting the network:
        - mock: stub a URL pattern with a custom status code and body
        - mocks: list active mock rules
        - remove_mock/clear_mocks: manage active mocks
        Mocks take priority over overrides and conditions.

        Per-domain rules: use 'url' to target specific endpoints (e.g., slow images but not API calls).
        Multiple conditions stack — latency adds up, first fail wins, lowest throttle wins.
        Use conditions/remove_condition/clear_conditions to manage active rules."""
        params: dict = {"action": action}
        if filter_text:
            params["filter"] = filter_text
        if limit is not None:
            params["limit"] = limit
        if max_body is not None:
            params["max_body"] = max_body
        if effect:
            params["effect"] = effect
        if latency_ms is not None:
            params["latency_ms"] = latency_ms
        if status_code is not None:
            params["status_code"] = status_code
        if error_domain:
            params["error_domain"] = error_domain
        if error_code is not None:
            params["error_code"] = error_code
        if bytes_per_second is not None:
            params["bytes_per_second"] = bytes_per_second
        if url:
            params["url"] = url
        if method:
            params["method"] = method
        if condition_id:
            params["id"] = condition_id
        if mock_status is not None:
            params["status"] = mock_status
        if mock_body is not None:
            params["body"] = mock_body
        if mock_id:
            params["id"] = mock_id
        return await resolve_and_send(simulator, "network", params)

    @mcp.tool()
    async def timeline(
        simulator: str | None = Field(default=None, description="Simulator UDID"),
        action: str = Field(default="query", description="Action: query, status, config, clear"),
        limit: int | None = Field(default=None, description="Max events to return (default 100)"),
        types: str | None = Field(default=None, description="Comma-separated event types: network, console, screen, command"),
        last_seconds: int | None = Field(default=None, description="Events from the last N seconds (convenience for since_ms)"),
        since_ms: int | None = Field(default=None, description="Only events after this epoch ms timestamp"),
        filter_text: str | None = Field(default=None, description="Filter events by summary substring"),
        buffer_size: int | None = Field(default=None, description="Set buffer size (for config action)"),
        recording: bool | None = Field(default=None, description="Enable/disable recording (for config action)"),
    ) -> str:
        """Always-on flight recorder timeline. Captures network requests, console logs, screen transitions,
        and command dispatch into a ring buffer — no setup needed. Query to correlate events when debugging."""
        params: dict = {"action": action}
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
    async def lifecycle(
        simulator: str | None = Field(default=None, description="Simulator UDID"),
        action: str = Field(description="Action: background, foreground, memory_warning"),
    ) -> str:
        """Trigger app lifecycle events (background/foreground/memory warning)."""
        return await resolve_and_send(simulator, "lifecycle", {"action": action})

    @mcp.tool()
    async def heap(
        simulator: str | None = Field(default=None, description="Simulator UDID"),
        action: str = Field(description="Action: classes, controllers, find, inspect, read, snapshot, diff, snapshot_clear, snapshot_status"),
        class_name: str | None = Field(default=None, description="Class name or pattern to search for"),
        pattern: str | None = Field(default=None, description="Pattern for classes search"),
        key_path: str | None = Field(default=None, description="KVC key path to read (for 'read' action, e.g. 'camera.zoom')"),
        limit: int | None = Field(default=None, description="Max results to return"),
        min_growth: int | None = Field(default=None, description="Min instance growth to report in diff (default: 1)"),
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
    async def accessibility_audit(
        simulator: str | None = Field(default=None, description="Simulator UDID"),
        checks: str | None = Field(
            default=None,
            description="Comma-separated checks to run (default: all). "
            "Options: missing_label, missing_trait, contrast, dynamic_type, touch_target, redundant_trait",
        ),
        severity: str | None = Field(
            default=None,
            description="Minimum severity to include: error, warning (default), info",
        ),
    ) -> str:
        """Scan the current screen for accessibility issues.

        Checks for: missing labels on interactive elements, invalid/missing traits,
        insufficient color contrast (WCAG 2.1 AA), fixed fonts without Dynamic Type,
        tap targets smaller than 44x44pt, and conflicting trait combinations.

        Returns a list of issues sorted by severity with element details and frames."""
        params: dict = {}
        if checks is not None:
            params["checks"] = checks
        if severity is not None:
            params["severity"] = severity
        return await resolve_and_send(simulator, "accessibility_audit", params, timeout=15)

    @mcp.tool()
    async def accessibility_action(
        simulator: str | None = Field(default=None, description="Simulator UDID"),
        action: str = Field(
            description="Action to perform: list, invoke, escape, magic_tap, increment, decrement"
        ),
        element: str | None = Field(
            default=None,
            description="Accessibility ID of the target element",
        ),
        text: str | None = Field(
            default=None,
            description="Text/label of the target element (alternative to element)",
        ),
        name: str | None = Field(
            default=None,
            description="Name of the custom action to invoke (for invoke action)",
        ),
        index: int | None = Field(
            default=None,
            description="Index of the custom action to invoke (for invoke action, alternative to name)",
        ),
    ) -> str:
        """Invoke accessibility actions on elements — test VoiceOver flows without VoiceOver.

        Actions:
        - list: List custom accessibility actions on an element.
        - invoke: Invoke a custom action by name or index.
        - escape: Trigger accessibilityPerformEscape() (two-finger Z gesture equivalent).
        - magic_tap: Trigger accessibilityPerformMagicTap() (two-finger double-tap equivalent).
        - increment: Call accessibilityIncrement() on adjustable elements (sliders, steppers).
        - decrement: Call accessibilityDecrement() on adjustable elements.

        For escape/magic_tap, element is optional — walks the responder chain from the current context."""
        params: dict = {"action": action}
        if element is not None:
            params["element"] = element
        if text is not None:
            params["text"] = text
        if name is not None:
            params["name"] = name
        if index is not None:
            params["index"] = index
        return await resolve_and_send(simulator, "accessibility_action", params)

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


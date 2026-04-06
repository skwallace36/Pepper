"""Debug and introspection tool definitions for Pepper MCP.

Tool definitions for: layers, console, crash_log, lifecycle, responder_chain,
notifications, constraints, timers, concurrency, loading, formatters, frameworks.
"""

from __future__ import annotations

import json
import os
import time

from pydantic import Field

from .mcp_crash import parse_crash_report
from .pepper_commands import (
    CMD_CONCURRENCY,
    CMD_CONSOLE,
    CMD_CONSTRAINTS,
    CMD_LAYERS,
    CMD_LIFECYCLE,
    CMD_NOTIFICATIONS,
    CMD_RESPONDER_CHAIN,
    CMD_TIMERS,
)
from .pepper_common import get_config


def register_debug_tools(mcp, resolve_and_send):
    """Register debug/introspection tools on the given MCP server.

    Args:
        mcp: FastMCP server instance.
        resolve_and_send: async (simulator, cmd, params?, timeout?) -> dict
    """

    @mcp.tool()
    async def layers(
        simulator: str | None = Field(default=None, description="Simulator UDID"),
        point: str = Field(description="Screen coordinates 'x,y' to inspect"),
        depth: int | None = Field(default=None, description="Max layer tree depth"),
    ) -> str:
        """Inspect the CALayer tree at a screen point — colors, shadows, corner radii, transforms, opacity, and bounds."""
        params: dict = {"point": point}
        if depth is not None:
            params["depth"] = depth
        return await resolve_and_send(simulator, CMD_LAYERS, params)

    @mcp.tool()
    async def console(
        simulator: str | None = Field(default=None, description="Simulator UDID"),
        action: str = Field(description="Action: start, stop, log"),
        filter_text: str | None = Field(default=None, description="Filter log lines (for log action)"),
        hide_noise: bool | None = Field(
            default=None,
            description="Hide known system framework noise — CFNetwork, Metal, AutoLayout, CoreData, etc. (default: true). Set false to see all.",
        ),
        exclude: str | None = Field(
            default=None,
            description="Comma-separated substrings to exclude from log (e.g. 'CoreData,Metal')",
        ),
        limit: int | None = Field(default=None, description="Max lines to return (for log action, default: 20)"),
        offset: int | None = Field(default=None, description="Skip this many recent lines for pagination (for log action, default: 0)"),
    ) -> str:
        """Capture and read app console output — both print() (stdout) and os_log/NSLog (stderr). Start, then log to read. System framework noise is filtered by default. Tip: use `timeline(last_seconds=30)` to see console events correlated with network and screen transitions."""
        params: dict = {"action": action}
        if filter_text:
            params["filter"] = filter_text
        if hide_noise is not None:
            params["hide_noise"] = hide_noise
        if exclude:
            params["exclude"] = exclude
        if limit is not None:
            params["limit"] = limit
        if offset is not None:
            params["offset"] = offset
        return await resolve_and_send(simulator, CMD_CONSOLE, params)

    @mcp.tool()
    async def crash_log(
        simulator: str | None = Field(default=None, description="Simulator UDID"),
        last_n: int = Field(default=1, description="Number of recent crash reports to show (default: 1, max: 5)"),
        seconds: int = Field(default=300, description="Look back this many seconds (default: 300 = 5 minutes)"),
    ) -> str:
        """Fetch and parse recent crash reports — exception type, reason, and symbolicated stack trace."""
        cfg = get_config()
        bundle_id = cfg.get("bundle_id", "")
        # Derive app name from bundle ID for fallback matching
        # e.g. "com.barkinglabs.fi" -> "fi", matches "Fi" case-insensitively
        app_name_hint = bundle_id.rsplit(".", 1)[-1].lower() if bundle_id else ""
        reports_dir = os.path.expanduser("~/Library/Logs/DiagnosticReports")

        if not os.path.isdir(reports_dir):
            return "No DiagnosticReports directory found."

        cutoff = time.time() - seconds
        last_n = min(last_n, 5)
        candidates = []
        all_app_reports = []  # All .ips matching our app (any age)
        try:
            for entry in os.scandir(reports_dir):
                if entry.name.endswith(".ips"):
                    try:
                        mtime = entry.stat().st_mtime
                        if mtime >= cutoff:
                            candidates.append((mtime, entry.path))
                        # Track all reports matching our app name for throttle detection
                        if app_name_hint:
                            fname_lower = entry.name.lower()
                            if fname_lower.startswith(app_name_hint + "-") or fname_lower.startswith(app_name_hint + "_"):
                                all_app_reports.append((mtime, entry.path))
                    except OSError:
                        pass
        except OSError:
            return "Failed to read DiagnosticReports directory."

        if not candidates:
            # No .ips files at all in the time window — check for throttling
            throttle_warning = ""
            if len(all_app_reports) >= 25:
                throttle_warning = (
                    f"\n\nWARNING: Found {len(all_app_reports)} total crash reports for "
                    f"'{app_name_hint}' across all time. macOS ReportCrash throttles "
                    f"after ~25 reports per process name. Delete old reports to reset:\n"
                    f"  rm ~/Library/Logs/DiagnosticReports/{app_name_hint.capitalize()}-*.ips"
                )
            return f"No crash reports found in the last {seconds}s.{throttle_warning}"

        candidates.sort(reverse=True)

        def _matches_app(content: str, filepath: str) -> bool:
            """Check if a crash report matches our app by bundle ID or app name."""
            if not bundle_id:
                return True
            # Primary: bundle ID string anywhere in content
            if bundle_id in content:
                return True
            # Fallback: match app_name in the JSON header or filename
            if app_name_hint:
                fname_lower = os.path.basename(filepath).lower()
                if fname_lower.startswith(app_name_hint + "-") or fname_lower.startswith(app_name_hint + "_"):
                    return True
                # Check header app_name field
                try:
                    header_line = content.split("\n", 1)[0]
                    header = json.loads(header_line)
                    header_app = header.get("app_name", "").lower()
                    if header_app == app_name_hint:
                        return True
                except (json.JSONDecodeError, IndexError):
                    pass
            return False

        # Filter by app identity
        results = []
        for _, path in candidates:
            if len(results) >= last_n:
                break
            try:
                with open(path) as f:
                    content = f.read()
                if not _matches_app(content, path):
                    continue
                parsed = parse_crash_report(path, content)
                if parsed:
                    results.append(parsed)
            except OSError:
                continue

        if not results:
            # List what was found for debugging
            other_names = set()
            for _, path in candidates[:10]:
                other_names.add(os.path.basename(path).split("-")[0])
            others_str = ", ".join(sorted(other_names)) if other_names else "none"

            throttle_warning = ""
            if len(all_app_reports) >= 25:
                throttle_warning = (
                    f"\nWARNING: macOS ReportCrash likely throttled — "
                    f"{len(all_app_reports)} reports exist for '{app_name_hint}'. "
                    f"Delete old reports to reset:\n"
                    f"  rm ~/Library/Logs/DiagnosticReports/{app_name_hint.capitalize()}-*.ips"
                )

            return (
                f"No crash reports matching {bundle_id} in the last {seconds}s. "
                f"Found {len(candidates)} total .ips files (from: {others_str}).{throttle_warning}"
            )

        return "\n".join(results)

    @mcp.tool()
    async def lifecycle(
        simulator: str | None = Field(default=None, description="Simulator UDID"),
        action: str = Field(description="Action: background, foreground, memory_warning"),
    ) -> str:
        """Trigger app lifecycle events — background, foreground, or memory_warning."""
        return await resolve_and_send(simulator, CMD_LIFECYCLE, {"action": action})

    @mcp.tool()
    async def responder_chain(
        simulator: str | None = Field(default=None, description="Simulator UDID"),
        point: str | None = Field(default=None, description="Screen coordinates 'x,y' to inspect"),
        element: str | None = Field(default=None, description="Accessibility identifier of the element"),
        text: str | None = Field(default=None, description="Text label of the element"),
    ) -> str:
        """Dump gesture recognizers, responder chain, and hit-test path for a point or element. Use when taps aren't working."""
        params: dict = {}
        if point:
            parts = point.split(",")
            if len(parts) == 2:
                params["point"] = {"x": float(parts[0]), "y": float(parts[1])}
        if element:
            params["element"] = element
        if text:
            params["text"] = text
        return await resolve_and_send(simulator, CMD_RESPONDER_CHAIN, params)

    @mcp.tool()
    async def notifications(
        simulator: str | None = Field(default=None, description="Simulator UDID"),
        action: str = Field(description="Action: start | stop | list | counts | post | events | status | clear"),
        name: str | None = Field(default=None, description="Notification name to post (for 'post' action)"),
        filter_text: str | None = Field(
            default=None, description="Filter observers/events by notification name or class pattern"
        ),
        user_info: dict | str | None = Field(
            default=None, description="userInfo dict to include when posting (for 'post' action)"
        ),
        limit: int | None = Field(default=None, description="Max results to return (for list/events actions)"),
    ) -> str:
        """Track NSNotificationCenter observers and post arbitrary notifications. Start tracking first, then list/count to inspect."""
        params = {"action": action}
        if name:
            params["name"] = name
        if filter_text:
            params["filter"] = filter_text
        if user_info is not None:
            if isinstance(user_info, str):
                try:
                    params["user_info"] = json.loads(user_info)
                except json.JSONDecodeError:
                    return "Error: user_info must be valid JSON"
            else:
                params["user_info"] = user_info
        if limit is not None:
            params["limit"] = limit
        return await resolve_and_send(simulator, CMD_NOTIFICATIONS, params)

    @mcp.tool()
    async def constraints(
        simulator: str | None = Field(default=None, description="Simulator UDID"),
        element: str | None = Field(default=None, description="Accessibility ID to scope to a subtree"),
        ambiguous_only: bool = Field(default=False, description="Only return views with ambiguous layout"),
        depth: int | None = Field(default=None, description="Max recursion depth (default: 30)"),
        mode: str | None = Field(
            default=None,
            description="Mode: 'constraints' (default) for AutoLayout constraints, "
            "'spacing' for margins/insets/stack spacing, "
            "'audit' to detect inconsistent gaps between siblings",
        ),
    ) -> str:
        """Dump AutoLayout constraints with ambiguity detection. Use mode='spacing' for margins/insets, mode='audit' to flag inconsistent gaps."""
        params: dict = {}
        if element:
            params["element"] = element
        if ambiguous_only:
            params["ambiguous_only"] = True
        if depth is not None:
            params["depth"] = depth
        if mode:
            params["mode"] = mode
        return await resolve_and_send(simulator, CMD_CONSTRAINTS, params)

    @mcp.tool()
    async def timers(
        simulator: str | None = Field(default=None, description="Simulator UDID"),
        action: str = Field(default="list", description="Action: start | stop | list | invalidate | status | clear"),
        timer_id: str | None = Field(
            default=None, description="Timer/display-link ID to invalidate (e.g. timer_3, dlink_1)"
        ),
        filter_text: str | None = Field(default=None, description="Filter by target class or selector name"),
        limit: int | None = Field(default=None, description="Max results to return (default 100)"),
    ) -> str:
        """Track active NSTimer and CADisplayLink instances. Start tracking first, then list to find leaked or unnecessary timers."""
        params: dict = {"action": action}
        if timer_id:
            params["id"] = timer_id
        if filter_text:
            params["filter"] = filter_text
        if limit is not None:
            params["limit"] = limit
        return await resolve_and_send(simulator, CMD_TIMERS, params)

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
        limit: int | None = Field(default=None, description="Max results to return"),
    ) -> str:
        """Inspect the Swift Concurrency runtime — active Tasks, actor classes, and executor state."""
        params: dict = {"action": action}
        if pattern:
            params["pattern"] = pattern
        if address:
            params["address"] = address
        if limit is not None:
            params["limit"] = limit
        return await resolve_and_send(simulator, CMD_CONCURRENCY, params)

    @mcp.tool()
    async def loading(
        simulator: str | None = Field(default=None, description="Simulator UDID"),
        include_network: bool = Field(
            default=True,
            description="Cross-reference with in-flight network requests (default true)",
        ),
    ) -> str:
        """Detect active loading indicators — spinners (UIActivityIndicatorView), progress bars (UIProgressView), and skeleton/shimmer views. Cross-references with in-flight network requests."""
        params: dict = {"include_network": include_network}
        return await resolve_and_send(simulator, "loading", params)

    @mcp.tool()
    async def formatters(
        simulator: str | None = Field(default=None, description="Simulator UDID"),
    ) -> str:
        """Inspect date/time formatting across visible labels. Detects format patterns (12h/24h, ISO 8601, slash/dot dates, relative dates), reports locale context, and flags inconsistencies like mixed clock formats."""
        params: dict = {}
        return await resolve_and_send(simulator, "formatters", params)

    @mcp.tool()
    async def frameworks(
        simulator: str | None = Field(default=None, description="Simulator UDID"),
        action: str = Field(
            default="list",
            description="Action: list (all loaded images), detail (single image info)",
        ),
        name: str | None = Field(
            default=None,
            description="Substring to match image name/path (required for detail)",
        ),
        filter: str | None = Field(
            default=None,
            description="Filter images by name substring (for list action)",
        ),
    ) -> str:
        """List loaded dylibs and frameworks with names, versions, UUIDs, and segment info. Shows app composition at a glance."""
        params: dict = {"action": action}
        if name is not None:
            params["name"] = name
        if filter is not None:
            params["filter"] = filter
        return await resolve_and_send(simulator, "frameworks", params)

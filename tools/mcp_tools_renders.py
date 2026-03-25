"""SwiftUI render tracking tool definitions for Pepper MCP.

Tool definitions for: renders
"""
from __future__ import annotations

from pepper_commands import CMD_RENDERS
from pydantic import Field


def register_renders_tools(mcp, resolve_and_send):
    """Register SwiftUI render tracking tools on the given MCP server.

    Args:
        mcp: FastMCP server instance.
        resolve_and_send: async (simulator, cmd, params?, timeout?) -> dict
    """

    @mcp.tool()
    async def renders(
        simulator: str | None = Field(default=None, description="Simulator UDID"),
        action: str = Field(
            description=(
                "Action: start, stop, status, log, clear, "
                "counts, snapshot, diff, reset, ag_probe, ag_server, ag_dump, signpost, why"
            )
        ),
        limit: int | None = Field(
            default=None, description="Max events to return (for log action, default 100)"
        ),
        since_ms: int | None = Field(
            default=None,
            description="Only return events after this Unix timestamp in ms (for log action)",
        ),
        filter: str | None = Field(
            default=None,
            description="Filter events by view controller type or address (for log action)",
        ),
        name: str | None = Field(
            default=None, description="Snapshot name (for ag_dump action)"
        ),
        sub: str | None = Field(
            default=None,
            description="Sub-action for signpost: install or drain",
        ),
    ) -> str:
        """Use this to track SwiftUI re-renders and diagnose excessive view body evaluations.

        Workflow:
        1. `renders start` — install swizzles on _UIHostingView to track renders
        2. Interact with the app to trigger re-renders
        3. `renders log` — see structured render events with per-view counts + summary
        4. `renders status` — quick check: active?, how many events?
        5. `renders stop` — uninstall swizzles (render counts stay until clear)
        6. `renders clear` — reset the event buffer

        Example: `renders start` → scroll a list → `renders log` → find the hottest view → `renders stop`.

        Actions:
        - start:     Install render swizzles (updateRootView, didRender, setNeedsUpdate)
        - stop:      Remove swizzles and return method call statistics
        - status:    Report active/inactive + event count + per-view render counts
        - log:       Structured event log with hosting view addresses, VC types, methods, counts.
                     Returns summary: total renders, hosting view count, hottest view.
                     Use limit/since_ms/filter to narrow results.
        - clear:     Clear the event ring buffer (keeps render counts)
        - counts:    Raw method call counts (layoutSubviews + spike methods)
        - snapshot:  Capture SwiftUI view tree via makeViewDebugData()
        - diff:      Compare current view tree against previous snapshot
        - reset:     Clear all data (counts + buffer + snapshots)
        - ag_probe:  Probe AttributeGraph private APIs — check symbol availability
        - ag_server: Start the AG debug server (if available on this iOS version)
        - ag_dump:   Dump the attribute graph to JSON via AGGraphArchiveJSON
        - signpost:  Install/drain os_signpost hook for SwiftUI events
        - why:       Experimental — combine AG probing + view tree diff to explain re-renders

        Related tools: vars_inspect (ViewModel state), network (API calls during renders),
        console (logs during renders), timeline (cross-cutting event timeline).
        """
        params: dict = {"action": action}
        if limit is not None:
            params["limit"] = limit
        if since_ms is not None:
            params["since_ms"] = since_ms
        if filter is not None:
            params["filter"] = filter
        if name is not None:
            params["name"] = name
        if sub is not None:
            params["sub"] = sub
        return await resolve_and_send(simulator, CMD_RENDERS, params)

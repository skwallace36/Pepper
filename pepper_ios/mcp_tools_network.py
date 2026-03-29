"""Network monitoring tool definitions for Pepper MCP.

Tool definitions for: network, timeline.
"""

from __future__ import annotations

import time

from pydantic import Field

from .pepper_commands import CMD_NETWORK, CMD_TIMELINE


def register_network_tools(mcp, resolve_and_send):
    """Register network monitoring tools on the given MCP server.

    Args:
        mcp: FastMCP server instance.
        resolve_and_send: async (simulator, cmd, params?, timeout?) -> dict
    """

    @mcp.tool()
    async def network(
        simulator: str | None = Field(default=None, description="Simulator UDID"),
        action: str = Field(
            description="Action: start, stop, log, status, clear, simulate, presets, conditions, remove_condition, clear_conditions, mock, mocks, remove_mock, clear_mocks"
        ),
        filter_text: str | None = Field(default=None, description="Filter by URL pattern (for log action)"),
        hide_noise: bool | None = Field(
            default=None,
            description="Hide known Apple/system telemetry traffic (default: true). Set false to see all requests.",
        ),
        exclude: str | None = Field(
            default=None,
            description="Comma-separated URL patterns to exclude from log (e.g. 'analytics.example.com,tracker.io')",
        ),
        limit: int | None = Field(default=None, description="Max entries to return (for log action, default: 10)"),
        offset: int | None = Field(default=None, description="Skip this many recent entries for pagination (for log action, default: 0)"),
        include_headers: bool | None = Field(
            default=None,
            description="Include request/response headers in log output (default: false)",
        ),
        include_body: bool | None = Field(
            default=None,
            description="Include request/response bodies in log output (default: false, enables max_body=4096)",
        ),
        max_body: int | None = Field(
            default=None,
            description="Max chars per body when include_body is true (default: 4096). Overrides include_body.",
        ),
        preset: str | None = Field(
            default=None,
            description="Named condition preset for simulate: 3G, Edge, LTE, WiFi, High Latency DNS, 100% Loss",
        ),
        effect: str | None = Field(
            default=None,
            description="Condition effect for simulate: latency, fail_status, fail_error, throttle, offline",
        ),
        latency_ms: int | None = Field(default=None, description="Latency in ms (for effect=latency)"),
        status_code: int | None = Field(default=None, description="HTTP status code (for effect=fail_status)"),
        error_domain: str | None = Field(
            default=None, description="NSError domain (for effect=fail_error, default: NSURLErrorDomain)"
        ),
        error_code: int | None = Field(default=None, description="NSError code (for effect=fail_error)"),
        bytes_per_second: int | None = Field(
            default=None, description="Bandwidth limit in bytes/sec (for effect=throttle)"
        ),
        url: str | None = Field(
            default=None, description="URL pattern to match (for simulate/mock — substring, case-insensitive)"
        ),
        method: str | None = Field(
            default=None, description="HTTP method to match (for simulate/mock — e.g., GET, POST)"
        ),
        condition_id: str | None = Field(
            default=None, description="Condition ID (for remove_condition, or custom ID for simulate)"
        ),
        mock_status_code: int | None = Field(default=None, description="HTTP status code for mock response (default: 200)"),
        mock_body: str | None = Field(default=None, description="Response body for mock (JSON string)"),
        mock_id: str | None = Field(default=None, description="Mock ID (for remove_mock, or custom ID for mock)"),
    ) -> str:
        """Monitor HTTP traffic, simulate network conditions (latency, errors, throttle, offline), and mock API responses. Tip: use `timeline(last_seconds=30)` to see network events correlated with console and screen transitions.

Common recipes (copy-paste ready):

1. Monitor traffic:
   action="start"
   action="log"                                          → last 10 requests (URL, status, duration)
   action="log", filter_text="api.example.com", limit=50 → filter by URL substring
   action="log", include_headers=True, include_body=True  → full request/response details
   action="status"                                        → interception state + active conditions/mocks

2. Mock an API endpoint:
   action="mock", url="api.example.com/users", mock_body='{"users": []}'
   action="mock", url="api.example.com/users", mock_status_code=201, mock_body='{"id": 1}', method="POST"
   action="mocks"              → list active mocks
   action="remove_mock", mock_id="<id from mock call>"
   action="clear_mocks"        → remove all mocks

3. Simulate slow network (3G-like):
   action="simulate", effect="throttle", bytes_per_second=50000
   action="simulate", effect="latency", latency_ms=300
   → Combine both for realistic 3G. Each creates a separate condition; use action="conditions" to list them.

4. Fail a specific URL:
   action="simulate", effect="fail_status", status_code=500, url="api.example.com/checkout"
   action="simulate", effect="fail_error", error_code=-1009, url="api.example.com"  → NSURLErrorNotConnectedToInternet
   action="simulate", effect="offline"                                                → all requests fail

5. Clean up:
   action="conditions"          → list active conditions (latency/throttle/fail)
   action="remove_condition", condition_id="<id>"
   action="clear_conditions"    → remove all conditions
   action="clear"               → clear captured traffic log
   action="stop"                → stop interception entirely

Parameter relationships:
- mock_status_code, mock_body, mock_id → only with action="mock"
- effect, latency_ms, status_code, error_domain, error_code, bytes_per_second → only with action="simulate"
- condition_id → action="simulate" (custom ID) or action="remove_condition"
- filter_text, limit, offset, include_headers, include_body, max_body, hide_noise, exclude → only with action="log"
- url, method → used by both action="simulate" and action="mock" to match requests"""
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
        if include_headers is not None:
            params["include_headers"] = include_headers
        if include_body is not None:
            params["include_body"] = include_body
        if max_body is not None:
            params["max_body"] = max_body
        if preset:
            params["preset"] = preset
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
        if condition_id and mock_id:
            return "Error: condition_id and mock_id are mutually exclusive — use condition_id for simulate/remove_condition, mock_id for mock/remove_mock."
        if condition_id:
            params["id"] = condition_id
        if mock_status_code is not None:
            params["status"] = mock_status_code
        if mock_body is not None:
            params["body"] = mock_body
        if mock_id:
            params["id"] = mock_id
        return await resolve_and_send(simulator, CMD_NETWORK, params)

    @mcp.tool()
    async def timeline(
        simulator: str | None = Field(default=None, description="Simulator UDID"),
        action: str = Field(default="query", description="Action: query, status, config, clear"),
        limit: int | None = Field(default=None, description="Max events to return (default 100)"),
        types: str | None = Field(
            default=None, description="Comma-separated event types: network, console, screen, command"
        ),
        last_seconds: int | None = Field(
            default=None, description="Events from the last N seconds (convenience for since_ms)"
        ),
        since_ms: int | None = Field(default=None, description="Only events after this epoch ms timestamp"),
        filter_text: str | None = Field(default=None, description="Filter events by summary substring"),
        buffer_size: int | None = Field(default=None, description="Set buffer size (for config action)"),
        recording: bool | None = Field(default=None, description="Enable/disable recording (for config action)"),
    ) -> str:
        """Always-on flight recorder — captures network, console, screen, and command events into a ring buffer. No setup needed."""
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
        return await resolve_and_send(simulator, CMD_TIMELINE, params)

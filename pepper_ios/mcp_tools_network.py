"""Network monitoring tool definitions for Pepper MCP.

Tool definitions for: network, network_mock, network_simulate, timeline.
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
            description="Action: start, stop, log, status, clear, tasks, stream_log"
        ),
        task_state: str | None = Field(
            default=None,
            description="Filter tasks by state: running, suspended, canceling, completed (for tasks action)",
        ),
        filter_text: str | None = Field(default=None, description="Filter by URL pattern (for log/tasks action)"),
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
        full_urls: bool | None = Field(
            default=None,
            description="Show full URLs with query strings (default: false — strips query params for compact output)",
        ),
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
        transaction_id: str | None = Field(
            default=None,
            description="Transaction ID of a streaming request (for stream_log action — get SSE/streaming chunks)",
        ),
    ) -> str:
        """Monitor HTTP traffic. Start interception, then query the log for captured requests.

Recipes:
  action="start"                                          → begin capturing
  action="log"                                            → last 10 requests
  action="log", filter_text="api.example.com", limit=50  → filter by URL
  action="log", include_headers=True, include_body=True   → full details
  action="tasks"                                          → active URLSession tasks
  action="tasks", task_state="running"                    → only running tasks
  action="stream_log", transaction_id="<id>"              → SSE/streaming chunks
  action="status"                                         → interception state
  action="clear"                                          → clear captured log
  action="stop"                                           → stop interception

Use network_mock for API mocking. Use network_simulate for latency/failures."""
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
        if full_urls is not None:
            params["full_urls"] = full_urls
        if include_headers is not None:
            params["include_headers"] = include_headers
        if include_body is not None:
            params["include_body"] = include_body
        if max_body is not None:
            params["max_body"] = max_body
        if task_state:
            params["state"] = task_state
        if transaction_id:
            params["id"] = transaction_id
        return await resolve_and_send(simulator, CMD_NETWORK, params)

    @mcp.tool()
    async def network_mock(
        simulator: str | None = Field(default=None, description="Simulator UDID"),
        action: str = Field(
            description="Action: mock, mocks, remove_mock, clear_mocks"
        ),
        url: str | None = Field(
            default=None, description="URL pattern to match (substring, case-insensitive)"
        ),
        method: str | None = Field(
            default=None, description="HTTP method to match (e.g., GET, POST)"
        ),
        mock_status_code: int | None = Field(default=None, description="HTTP status code for mock response (default: 200)"),
        mock_body: str | None = Field(default=None, description="Response body for mock (JSON string)"),
        mock_id: str | None = Field(default=None, description="Mock ID (for remove_mock, or custom ID for mock)"),
    ) -> str:
        """Mock API responses. Intercept requests matching a URL pattern and return a custom response.

Recipes:
  action="mock", url="api.example.com/users", mock_body='{"users": []}'
  action="mock", url="api.example.com/users", mock_status_code=201, mock_body='{"id": 1}', method="POST"
  action="mocks"                                          → list active mocks
  action="remove_mock", mock_id="<id from mock call>"
  action="clear_mocks"                                    → remove all mocks

Requires network interception to be running (network action="start")."""
        params: dict = {"action": action}
        if url:
            params["url"] = url
        if method:
            params["method"] = method
        if mock_status_code is not None:
            params["status"] = mock_status_code
        if mock_body is not None:
            params["body"] = mock_body
        if mock_id:
            params["id"] = mock_id
        return await resolve_and_send(simulator, CMD_NETWORK, params)

    @mcp.tool()
    async def network_simulate(
        simulator: str | None = Field(default=None, description="Simulator UDID"),
        action: str = Field(
            description="Action: simulate, presets, conditions, remove_condition, clear_conditions"
        ),
        effect: str | None = Field(
            default=None,
            description="Condition effect: latency, fail_status, fail_error, throttle, offline",
        ),
        preset: str | None = Field(
            default=None,
            description="Named preset instead of manual effect: 3G, Edge, LTE, WiFi, High Latency DNS, 100% Loss",
        ),
        url: str | None = Field(
            default=None, description="URL pattern to match (substring, case-insensitive). Omit for all requests."
        ),
        method: str | None = Field(
            default=None, description="HTTP method to match (e.g., GET, POST)"
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
        condition_id: str | None = Field(
            default=None, description="Condition ID (for remove_condition, or custom ID for simulate)"
        ),
    ) -> str:
        """Simulate network conditions — add latency, throttle bandwidth, fail requests, or go offline.

Recipes:
  action="simulate", effect="latency", latency_ms=300                    → add 300ms latency
  action="simulate", effect="throttle", bytes_per_second=50000           → 3G-like bandwidth
  action="simulate", effect="fail_status", status_code=500, url="checkout" → fail specific URL
  action="simulate", effect="fail_error", error_code=-1009               → NSURLErrorNotConnectedToInternet
  action="simulate", effect="offline"                                     → all requests fail
  action="simulate", preset="3G"                                          → named preset
  action="presets"                                                        → list available presets
  action="conditions"                                                     → list active conditions
  action="remove_condition", condition_id="<id>"
  action="clear_conditions"                                               → remove all

Requires network interception to be running (network action="start")."""
        params: dict = {"action": action}
        if effect:
            params["effect"] = effect
        if preset:
            params["preset"] = preset
        if url:
            params["url"] = url
        if method:
            params["method"] = method
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
        if condition_id:
            params["id"] = condition_id
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

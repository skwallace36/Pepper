"""Network monitoring tool definitions for Pepper MCP.

Tool definitions for: network, timeline.
"""
from __future__ import annotations

import time

from pepper_commands import CMD_NETWORK, CMD_TIMELINE
from pydantic import Field


def register_network_tools(mcp, resolve_and_send):
    """Register network monitoring tools on the given MCP server.

    Args:
        mcp: FastMCP server instance.
        resolve_and_send: async (simulator, cmd, params?, timeout?) -> str
    """

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
        return await resolve_and_send(simulator, CMD_NETWORK, params)

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
        return await resolve_and_send(simulator, CMD_TIMELINE, params)

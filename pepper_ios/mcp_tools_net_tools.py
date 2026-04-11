"""Grouped network tools — mock, simulate, http_call, timeline as subcommands."""

from __future__ import annotations

import json
import logging
import time

import httpx
from pydantic import Field

from .pepper_commands import CMD_NETWORK, CMD_TIMELINE

logger = logging.getLogger(__name__)

# Reusable async client — connection pooling across calls.
_client: httpx.AsyncClient | None = None


def _get_client() -> httpx.AsyncClient:
    global _client
    if _client is None:
        _client = httpx.AsyncClient(timeout=30, follow_redirects=True)
    return _client


def register_net_grouped_tools(mcp, resolve_and_send):
    """Register the net_tools grouped tool.

    Args:
        mcp: FastMCP server instance.
        resolve_and_send: async (simulator, cmd, params?, timeout?) -> str (JSON)
    """

    @mcp.tool(name="net_tools")
    async def net_tools(
        command: str = Field(
            description="Subcommand: mock | simulate | http_call | timeline"
        ),
        simulator: str | None = Field(default=None, description="Simulator UDID"),
        # mock params
        action: str | None = Field(default=None, description="[mock] add/remove/list/clear; [simulate] add/remove/list/clear/preset; [timeline] start/stop/log/status/clear"),
        url: str | None = Field(default=None, description="[mock/simulate/http_call] URL pattern or full URL"),
        method: str | None = Field(default=None, description="[mock/simulate/http_call] HTTP method"),
        mock_status_code: int | None = Field(default=None, description="[mock] Response status code"),
        mock_body: str | None = Field(default=None, description="[mock] Response body (JSON string or text)"),
        mock_id: str | None = Field(default=None, description="[mock/simulate] Mock/condition ID for remove"),
        # simulate params
        effect: str | None = Field(default=None, description="[simulate] Effect: latency, error, throttle"),
        preset: str | None = Field(default=None, description="[simulate] Preset: offline, slow_3g, lossy, flaky"),
        latency_ms: int | None = Field(default=None, description="[simulate] Latency in milliseconds"),
        status_code: int | None = Field(default=None, description="[simulate] Error status code"),
        error_domain: str | None = Field(default=None, description="[simulate] NSError domain"),
        error_code: int | None = Field(default=None, description="[simulate] NSError code"),
        bytes_per_second: int | None = Field(default=None, description="[simulate] Throttle rate"),
        condition_id: str | None = Field(default=None, description="[simulate] Condition ID for remove"),
        # http_call params
        headers: str | dict | None = Field(default=None, description="[http_call] Headers as JSON string or object"),
        body: str | dict | list | None = Field(default=None, description="[http_call] Request body"),
        content_type: str | None = Field(default=None, description="[http_call] Content-Type header"),
        timeout: int | None = Field(default=None, description="[http_call] Request timeout in seconds"),
        # timeline params
        limit: int | None = Field(default=None, description="[timeline] Max events to return"),
        types: list[str] | None = Field(default=None, description="[timeline] Filter by event types"),
        last_seconds: int | None = Field(default=None, description="[timeline] Only events from last N seconds"),
        since_ms: int | None = Field(default=None, description="[timeline] Only events after this epoch-ms"),
        filter_text: str | None = Field(default=None, description="[timeline] Filter events by text"),
        buffer_size: int | None = Field(default=None, description="[timeline] Set buffer size"),
        recording: bool | None = Field(default=None, description="[timeline] Enable/disable recording"),
    ) -> str:
        """Network tools beyond basic monitoring. Subcommands:
        - mock: Mock API responses (add/remove/list/clear)
        - simulate: Simulate network conditions (latency, throttle, errors, presets)
        - http_call: Make HTTP request to any URL (REST APIs, webhooks)
        - timeline: Always-on flight recorder for network/console/screen events"""

        if command == "mock":
            params: dict = {"action": action or "list"}
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

        elif command == "simulate":
            params = {"action": action or "list"}
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

        elif command == "http_call":
            if not url:
                return "Error: url required for http_call"
            client = _get_client()
            req_headers: dict = {}
            if headers:
                if isinstance(headers, dict):
                    req_headers = headers
                else:
                    try:
                        req_headers = json.loads(headers)
                    except json.JSONDecodeError as e:
                        return f"Invalid headers JSON: {e}"
            body_str: str | None = None
            if body is not None:
                body_str = json.dumps(body) if isinstance(body, (dict, list)) else body
            if content_type:
                req_headers["Content-Type"] = content_type
            elif body_str and "Content-Type" not in req_headers and "content-type" not in req_headers:
                req_headers["Content-Type"] = "application/json"
            kwargs: dict = {
                "method": (method or "POST").upper(),
                "url": url,
                "headers": req_headers,
                "timeout": timeout or 30,
            }
            if body_str is not None:
                kwargs["content"] = body_str.encode("utf-8")
            start = time.monotonic()
            try:
                resp = await client.request(**kwargs)
            except httpx.TimeoutException:
                return f"Request timed out after {timeout or 30}s"
            except httpx.ConnectError as e:
                return f"Connection failed: {e}"
            except httpx.RequestError as e:
                return f"Request error: {e}"
            elapsed_ms = int((time.monotonic() - start) * 1000)
            parts = [f"HTTP {resp.status_code} ({elapsed_ms}ms)"]
            ct_resp = resp.headers.get("content-type", "")
            if ct_resp:
                parts.append(f"Content-Type: {ct_resp}")
            body_text = resp.text
            if len(body_text) > 8192:
                body_text = body_text[:8192] + f"\n... (truncated, {len(resp.text)} total chars)"
            if "json" in ct_resp:
                try:
                    parsed = json.loads(resp.text)
                    body_text = json.dumps(parsed, indent=2)
                    if len(body_text) > 8192:
                        body_text = body_text[:8192] + "\n... (truncated)"
                except json.JSONDecodeError:
                    pass
            if body_text:
                parts.append(f"\n{body_text}")
            return "\n".join(parts)

        elif command == "timeline":
            params = {"action": action or "log"}
            if limit is not None:
                params["limit"] = limit
            if types:
                params["types"] = types
            if since_ms is not None:
                params["since_ms"] = since_ms
            elif last_seconds is not None:
                params["since_ms"] = int(time.time() * 1000) - last_seconds * 1000
            if filter_text:
                params["filter"] = filter_text
            if buffer_size is not None:
                params["buffer_size"] = buffer_size
            if recording is not None:
                params["recording"] = recording
            return await resolve_and_send(simulator, CMD_TIMELINE, params)

        return f"Unknown command '{command}'. Use: mock, simulate, http_call, timeline"

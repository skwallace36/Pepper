"""HTTP call tool for Pepper MCP.

Generic HTTP client — call any endpoint (REST APIs, Firebase cloud functions, webhooks).
Runs Python-side, no dylib dependency.
"""

from __future__ import annotations

import json
import logging
import time

import httpx
from pydantic import Field

logger = logging.getLogger(__name__)

# Reusable async client — connection pooling across calls.
_client: httpx.AsyncClient | None = None


def _get_client() -> httpx.AsyncClient:
    global _client
    if _client is None:
        _client = httpx.AsyncClient(timeout=30, follow_redirects=True)
    return _client


def register_http_tools(mcp):
    """Register HTTP tools on the given MCP server."""

    @mcp.tool()
    async def http_call(
        url: str = Field(description="Full URL to call (e.g. https://us-central1-myproject.cloudfunctions.net/seedScenario)"),
        method: str = Field(default="POST", description="HTTP method: GET, POST, PUT, PATCH, DELETE, HEAD"),
        headers: str | dict | None = Field(default=None, description="Headers as JSON string or object (e.g. '{\"Authorization\": \"Bearer token\"}')"),
        body: str | dict | list | None = Field(default=None, description="Request body — JSON object/array or string. Objects are auto-serialized to JSON."),
        content_type: str | None = Field(default=None, description="Content-Type header (default: application/json when body is provided)"),
        timeout: int = Field(default=30, description="Request timeout in seconds (default: 30)"),
    ) -> str:
        """Make an HTTP request to any URL. Use for calling cloud functions, REST APIs, webhooks, or any HTTP endpoint.

Examples:

1. Firebase callable function:
   url="https://us-central1-myproject.cloudfunctions.net/seedScenario"
   body='{"data": {"scenario": "member_with_activity"}}'

2. REST API GET:
   url="https://api.example.com/users", method="GET"

3. POST with auth:
   url="https://api.example.com/reset"
   headers='{"Authorization": "Bearer sk-..."}'
   body='{"user_id": "123"}'

4. Delete resource:
   url="https://api.example.com/users/123", method="DELETE"
"""
        client = _get_client()

        # Parse headers — accept dict directly or JSON string
        req_headers = {}
        if headers:
            if isinstance(headers, dict):
                req_headers = headers
            else:
                try:
                    req_headers = json.loads(headers)
                except json.JSONDecodeError as e:
                    return f"Invalid headers JSON: {e}"

        # Normalize body — dicts/lists get serialized to JSON string
        body_str: str | None = None
        if body is not None:
            body_str = json.dumps(body) if isinstance(body, (dict, list)) else body

        # Set content type
        if content_type:
            req_headers["Content-Type"] = content_type
        elif body_str and "Content-Type" not in req_headers and "content-type" not in req_headers:
            req_headers["Content-Type"] = "application/json"

        # Build request kwargs
        kwargs: dict = {
            "method": method.upper(),
            "url": url,
            "headers": req_headers,
            "timeout": timeout,
        }

        if body_str is not None:
            kwargs["content"] = body_str.encode("utf-8")

        start = time.monotonic()
        try:
            resp = await client.request(**kwargs)
        except httpx.TimeoutException:
            return f"Request timed out after {timeout}s"
        except httpx.ConnectError as e:
            return f"Connection failed: {e}"
        except httpx.RequestError as e:
            return f"Request error: {e}"
        elapsed_ms = int((time.monotonic() - start) * 1000)

        # Format response
        parts = [f"HTTP {resp.status_code} ({elapsed_ms}ms)"]

        # Include response headers summary
        ct_resp = resp.headers.get("content-type", "")
        if ct_resp:
            parts.append(f"Content-Type: {ct_resp}")

        # Response body
        body_text = resp.text
        if len(body_text) > 8192:
            body_text = body_text[:8192] + f"\n... (truncated, {len(resp.text)} total chars)"

        # Pretty-print JSON responses
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

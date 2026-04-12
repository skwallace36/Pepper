"""State tool definitions for Pepper MCP.

Standalone tool: state_vars. Other state tools moved to state_tools grouped tool.
"""

from __future__ import annotations

from pydantic import Field

from .pepper_commands import CMD_VARS
from .pepper_common import try_parse_json


def register_state_tools(mcp, resolve_and_send):
    """Register standalone state tools (vars_inspect only).

    Args:
        mcp: FastMCP server instance.
        resolve_and_send: async (simulator, cmd, params?, timeout?) -> str (JSON)
    """

    @mcp.tool(name="state_vars")
    async def vars_inspect(
        simulator: str | None = Field(default=None, description="Simulator UDID"),
        action: str = Field(description="Action: list | dump | mirror | set | discover"),
        class_name: str | None = Field(default=None, description="ViewModel class name (for dump/mirror/set/list filter)"),
        path: str | None = Field(default=None, description="Property path (for set, e.g. 'MyVM.flag')"),
        value: str | None = Field(default=None, description="Value to set (for set action)"),
        limit: int | None = Field(default=None, description="Max results for list/discover (default 50, prevents crashes on large apps)"),
    ) -> str:
        """Check or change ViewModel @Published properties at runtime — no rebuild needed."""
        params: dict = {"action": action}
        if class_name:
            params["class"] = class_name
        if path:
            params["path"] = path
        if value is not None:
            params["value"] = try_parse_json(value)
        if limit is not None:
            params["limit"] = limit
        # Heap scan on first call can take 30+s — needs longer timeout
        return await resolve_and_send(simulator, CMD_VARS, params, timeout=45)

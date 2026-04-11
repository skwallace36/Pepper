"""Element control tool definitions for Pepper MCP.

Standalone tool: ui_toggle. Other element tools moved to ui_query grouped tool.
"""

from __future__ import annotations

from pydantic import Field

from .pepper_commands import CMD_TOGGLE


def register_element_tools(mcp, resolve_and_send, act_and_look):
    """Register standalone element tools (toggle only).

    Args:
        mcp: FastMCP server instance.
        resolve_and_send: async (simulator, cmd, params?, timeout?) -> str (JSON)
        act_and_look: async (simulator, cmd, params?, timeout?) -> list
    """

    @mcp.tool(name="ui_toggle")
    async def toggle(
        simulator: str | None = Field(default=None, description="Simulator UDID"),
        element: str = Field(description="Accessibility ID of the switch/segment to toggle"),
        value: int | None = Field(default=None, description="Target segment index (for segmented controls)"),
    ) -> list:
        """Flip a switch or change a segmented control by accessibility ID. Prefer over tap for switches. Shows screen state after."""
        params: dict = {"element": element}
        if value is not None:
            params["value"] = value
        return await act_and_look(simulator, CMD_TOGGLE, params)

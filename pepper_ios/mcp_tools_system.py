"""System tool definitions for Pepper MCP.

Standalone tools: app_status, ui_gesture. Other system tools moved to sys_tools grouped tool.
"""

from __future__ import annotations

from pydantic import Field

from .pepper_commands import CMD_GESTURE, CMD_MEMORY, CMD_STATUS


def register_system_tools(mcp, resolve_and_send, act_and_look):
    """Register standalone system tools (status, gesture only).

    Args:
        mcp: FastMCP server instance.
        resolve_and_send: async (simulator, cmd, params?, timeout?) -> str (formatted text)
        act_and_look: async (simulator, cmd, params?, timeout?) -> list
    """

    @mcp.tool(name="app_status")
    async def status(
        simulator: str | None = Field(default=None, description="Simulator UDID"),
        memory: bool = Field(
            default=False, description="Include process memory stats (resident size, virtual size, footprint)"
        ),
        memory_detail: bool = Field(
            default=False, description="Include detailed VM breakdown (internal, compressed, purgeable)"
        ),
    ) -> list:
        """Check Pepper connection health — bundle ID, version, port, connections, current screen. Add memory=true for process memory stats."""
        if not memory and not memory_detail:
            return await resolve_and_send(simulator, CMD_STATUS)
        # Need to merge status + memory, so use raw dict path
        from .mcp_server import resolve_and_send as raw_send
        from .pepper_format import format_data, text_content

        result = await raw_send(simulator, CMD_STATUS)
        if result.get("status") != "ok":
            return text_content(f"Error: {result.get('error', 'unknown')}")
        data = result.get("data", {})
        mem_params: dict = {}
        if memory_detail:
            mem_params["action"] = "vm"
        mem_result = await raw_send(simulator, CMD_MEMORY, mem_params)
        data["memory"] = mem_result.get("data", mem_result)
        return text_content(format_data(data))

    @mcp.tool(name="ui_gesture")
    async def gesture(
        simulator: str | None = Field(default=None, description="Simulator UDID"),
        type: str = Field(description="Gesture type: 'pinch' for zoom in/out, 'rotate' for two-finger rotation"),
        start_distance: int | None = Field(default=None, description="Starting distance between fingers in points (for pinch; e.g. 200 to start wide)"),
        end_distance: int | None = Field(default=None, description="Ending distance between fingers in points (for pinch; e.g. 50 to zoom in, 300 to zoom out)"),
        angle: float | None = Field(default=None, description="Rotation angle in degrees (for rotate; e.g. 90 for quarter turn, -45 for reverse)"),
        center_x: float | None = Field(default=None, description="Center X coordinate — defaults to screen center (e.g. 200.0)"),
        center_y: float | None = Field(default=None, description="Center Y coordinate — defaults to screen center (e.g. 400.0)"),
    ) -> list:
        """Use this for multi-touch gestures like pinch-to-zoom or two-finger rotation on maps, images, or zoomable views.
        Synthesizes two-finger touch events via HID injection. Shows screen state after."""
        params: dict = {"type": type}
        if start_distance is not None:
            params["start_distance"] = start_distance
        if end_distance is not None:
            params["end_distance"] = end_distance
        if angle is not None:
            params["angle"] = angle
        if center_x is not None or center_y is not None:
            params["center"] = {}
            if center_x is not None:
                params["center"]["x"] = center_x
            if center_y is not None:
                params["center"]["y"] = center_y
        return await act_and_look(simulator, CMD_GESTURE, params)

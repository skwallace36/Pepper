"""System and utility tool definitions for Pepper MCP.

Tools: push, status, highlight, orientation, locale, gesture, hook, flags.
"""
from __future__ import annotations

import json

from pepper_commands import (
    CMD_FLAGS,
    CMD_GESTURE,
    CMD_HIGHLIGHT,
    CMD_HOOK,
    CMD_LOCALE,
    CMD_MEMORY,
    CMD_ORIENTATION,
    CMD_PUSH,
    CMD_STATUS,
)
from pepper_common import require_parse_json, try_parse_json
from pydantic import Field


def register_system_tools(mcp, resolve_and_send, act_and_look):
    """Register system/utility tools on the given MCP server.

    Args:
        mcp: FastMCP server instance.
        resolve_and_send: async (simulator, cmd, params?, timeout?) -> dict
        act_and_look: async (simulator, cmd, params?, timeout?) -> str
    """

    @mcp.tool()
    async def push(
        simulator: str | None = Field(default=None, description="Simulator UDID"),
        action: str | None = Field(default=None, description="Action: deliver (default), pending, clear"),
        title: str | None = Field(default=None, description="Notification title"),
        body: str | None = Field(default=None, description="Notification body text"),
        data: str | None = Field(
            default=None, description='JSON userInfo payload for deeplink routing (e.g. \'{"type":"order_detail"}\')'
        ),
    ) -> str:
        """Simulate push notifications in the running app.

        Delivered notifications appear exactly like real APNs pushes — banner, sound, badge.
        Include a data payload to test deeplink routing (the app receives it in userInfo).
        Use action='pending' to list queued notifications, action='clear' to remove them all."""
        params: dict = {}
        if action:
            params["action"] = action
        if title:
            params["title"] = title
        if body:
            params["body"] = body
        if data:
            try:
                params["data"] = require_parse_json(data, "data")
            except ValueError as e:
                return f"Error: {e}"
        return await resolve_and_send(simulator, CMD_PUSH, params)

    @mcp.tool()
    async def status(
        simulator: str | None = Field(default=None, description="Simulator UDID"),
        memory: bool = Field(
            default=False, description="Include process memory stats (resident size, virtual size, footprint)"
        ),
        memory_detail: bool = Field(
            default=False, description="Include detailed VM breakdown (internal, compressed, purgeable)"
        ),
    ) -> str:
        """Check Pepper connection health and app identity.

        Returns: bundle ID, app version, Pepper server port, active WebSocket connections, current screen name.
        Call after deploy to confirm Pepper connected successfully, or anytime to identify the current screen.
        Add memory=true for process memory (resident size, footprint), memory_detail=true for full VM breakdown."""
        result = await resolve_and_send(simulator, CMD_STATUS)
        if memory or memory_detail:
            mem_params: dict = {}
            if memory_detail:
                mem_params["action"] = "vm"
            mem_result = await resolve_and_send(simulator, CMD_MEMORY, mem_params)
            if isinstance(result, str):
                result = json.loads(result)
            if isinstance(mem_result, str):
                mem_result = json.loads(mem_result)
            result["memory"] = mem_result.get("data", mem_result)
            return json.dumps(result, indent=2)
        return result

    @mcp.tool()
    async def highlight(
        simulator: str | None = Field(default=None, description="Simulator UDID"),
        text: str | None = Field(default=None, description="Highlight element by text label"),
        frame: str | None = Field(default=None, description="Highlight a frame: 'x,y,width,height'"),
        color: str | None = Field(
            default=None, description="Color name (blue/green/red/yellow/purple) or hex (#ff0000)"
        ),
        label: str | None = Field(default=None, description="Label text to show on the highlight"),
        duration: float | None = Field(default=None, description="How long to show in seconds (default: 0.8)"),
        clear: bool = Field(default=False, description="Clear all highlights"),
    ) -> str:
        """Draw a colored border around an element for visual debugging. Visible in screenshots and recordings.

        Specify text to highlight by label, or frame for exact coordinates.
        Highlights render as real UIViews overlaid on the app. Use clear=true to remove all."""
        params: dict = {}
        if clear:
            params["clear"] = True
        elif text:
            params["text"] = text
        elif frame:
            try:
                parts = [float(x) for x in frame.split(",")]
                params["frame"] = {"x": parts[0], "y": parts[1], "width": parts[2], "height": parts[3]}
            except (ValueError, IndexError):
                return "Error: frame must be 'x,y,width,height' (e.g. '10,100,200,44')"
        if color:
            params["color"] = color
        if label:
            params["label"] = label
        if duration is not None:
            params["duration"] = duration
        return await resolve_and_send(simulator, CMD_HIGHLIGHT, params)

    @mcp.tool()
    async def orientation(
        simulator: str | None = Field(default=None, description="Simulator UDID"),
        value: str | None = Field(
            default=None,
            description="Target orientation: portrait, landscape_left, landscape_right, portrait_upside_down",
        ),
    ) -> str:
        """Get or set device orientation. Omit value to query; set to rotate the device programmatically."""
        params: dict = {}
        if value:
            params["value"] = value
        return await resolve_and_send(simulator, CMD_ORIENTATION, params)

    @mcp.tool()
    async def locale(
        simulator: str | None = Field(default=None, description="Simulator UDID"),
        action: str | None = Field(
            default=None, description="Action: current (default), set, reset, lookup, languages"
        ),
        language: str | None = Field(default=None, description="Language code for set/lookup (e.g. 'es', 'ja')"),
        region: str | None = Field(default=None, description="Region code for set (e.g. 'JP', 'US')"),
        key: str | None = Field(default=None, description="Localization key to look up (for lookup action)"),
    ) -> str:
        """Override app locale at runtime without changing simulator settings.

        Actions: current (read locale), set (override language/region), reset (restore original),
        lookup (find a localized string by key), languages (list available localizations)."""
        params: dict = {}
        if action:
            params["action"] = action
        if language:
            params["language"] = language
        if region:
            params["region"] = region
        if key:
            params["key"] = key
        return await resolve_and_send(simulator, CMD_LOCALE, params)

    @mcp.tool()
    async def gesture(
        simulator: str | None = Field(default=None, description="Simulator UDID"),
        type: str = Field(description="Gesture type: pinch or rotate"),
        start_distance: int | None = Field(default=None, description="Starting pinch distance in points (for pinch)"),
        end_distance: int | None = Field(default=None, description="Ending pinch distance in points (for pinch)"),
        angle: float | None = Field(default=None, description="Rotation angle in degrees (for rotate)"),
        center_x: float | None = Field(default=None, description="Center X coordinate (defaults to screen center)"),
        center_y: float | None = Field(default=None, description="Center Y coordinate (defaults to screen center)"),
    ) -> str:
        """Perform multi-touch gestures — pinch to zoom or two-finger rotate. Shows screen state after.

        Pinch: set start_distance and end_distance in points. Larger end = zoom in, smaller = zoom out.
        Rotate: set angle in degrees.
        Center defaults to screen center; override with center_x/center_y to target a specific view.

        Pinch may not work on views with custom gesture recognizers (e.g. map SDKs).
        If it doesn't take effect, try defaults or vars_inspect to change zoom state directly."""
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

    @mcp.tool()
    async def hook(
        simulator: str | None = Field(default=None, description="Simulator UDID"),
        action: str = Field(default="list", description="Action: install, remove, remove_all, list, log, clear"),
        class_name: str | None = Field(
            default=None, description="ObjC class name (for install, e.g. 'UIViewController')"
        ),
        method: str | None = Field(default=None, description="ObjC method name (for install, e.g. 'viewDidAppear:')"),
        class_method: bool = Field(default=False, description="Hook class method (+) instead of instance method (-)"),
        hook_id: str | None = Field(default=None, description="Hook ID (for remove, log, clear)"),
        limit: int | None = Field(default=None, description="Max log entries to return (default: 50)"),
    ) -> str:
        """Hook ObjC methods at runtime to log every invocation. Non-destructive — the original method runs normally.

        install: attach a hook (class_name + method required). remove: detach by hook_id.
        list: show active hooks. log: read captured invocations for a hook_id. clear: wipe log entries.

        Supports void/object/BOOL return types with 0-3 object args, plus void+BOOL.
        Covers lifecycle, delegate, network, and analytics methods.

        Example: hook action=install class_name=UIViewController method="viewDidAppear:" """
        params: dict = {"action": action}
        if class_name:
            params["class"] = class_name
        if method:
            params["method"] = method
        if class_method:
            params["class_method"] = True
        if hook_id:
            params["id"] = hook_id
        if limit is not None:
            params["limit"] = limit
        return await resolve_and_send(simulator, CMD_HOOK, params)

    @mcp.tool()
    async def flags(
        simulator: str | None = Field(default=None, description="Simulator UDID"),
        action: str = Field(default="list", description="Action: list, get, set, clear"),
        key: str | None = Field(default=None, description="Feature flag key"),
        value: str | None = Field(default=None, description="Value to set (true/false for bools, or string/int)"),
    ) -> str:
        """Override feature flags by intercepting the network response that delivers them.

        The app receives modified flag data through its normal code path — no timing races.
        Overrides persist across deploys until explicitly cleared.

        Workflow: flags set key="flag" value="true" → deploy (restart) → look (verify).

        Actions: list (show overrides + status), get (read one flag), set (override a flag),
        clear (remove one override by key, or all if no key)."""
        params: dict = {"action": action}
        if key:
            params["key"] = key
        if value is not None:
            params["value"] = try_parse_json(value)
        return await resolve_and_send(simulator, CMD_FLAGS, params)

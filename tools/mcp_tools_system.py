"""System and utility tool definitions for Pepper MCP.

Tool definitions for: push, status, highlight, orientation, locale,
gesture, hook, find, flags, dialog, toggle, read_element, tree.
"""

import json
from typing import Optional

from pydantic import Field


def try_parse_json(value):
    """Try to parse a string as JSON for proper typing (bool, int, dict, list).
    Returns the parsed value on success, or the original string on failure."""
    if value is None:
        return None
    try:
        return json.loads(value)
    except (json.JSONDecodeError, TypeError):
        return value


def require_parse_json(value, field_name="value"):
    """Parse a string as JSON, raising ValueError with a descriptive message on failure."""
    try:
        return json.loads(value)
    except json.JSONDecodeError as e:
        raise ValueError(f"{field_name} must be valid JSON: {e}")


def register_system_tools(mcp, resolve_and_send, act_and_look):
    """Register system/utility tools on the given MCP server.

    Args:
        mcp: FastMCP server instance.
        resolve_and_send: async (simulator, cmd, params?, timeout?) -> str
        act_and_look: async (simulator, cmd, params?, timeout?) -> str
    """

    @mcp.tool()
    async def dialog(
        simulator: Optional[str] = Field(default=None, description="Simulator UDID"),
        action: str = Field(description="Action: list, current, dismiss, detect_system, auto_dismiss, share_sheet, dismiss_sheet"),
        button: Optional[str] = Field(default=None, description="Button title to tap (for dismiss action)"),
        enabled: Optional[bool] = Field(default=None, description="Enable/disable auto-dismiss (for auto_dismiss action)"),
        buttons: Optional[str] = Field(default=None, description="JSON array of button titles for auto-dismiss (e.g. '[\"Allow\",\"OK\"]')"),
    ) -> str:
        """Interact with system dialogs (alerts, permission prompts, share sheets).
        - list: see all pending dialogs
        - current: get the topmost dialog
        - dismiss: tap a button on the current dialog
        - detect_system: actively check for system dialog presence (key window status, hit-test probe, window hierarchy) with confidence level
        - auto_dismiss: auto-handle permission dialogs (Allow, OK, etc.)
        - share_sheet: check if a share sheet is showing
        - dismiss_sheet: close the share sheet"""
        params: dict = {"action": action}
        if button:
            params["button"] = button
        if enabled is not None:
            params["enabled"] = enabled
        if buttons:
            try:
                params["buttons"] = require_parse_json(buttons, "buttons")
            except ValueError as e:
                return f"Error: {e}"
        return await resolve_and_send(simulator, "dialog", params)

    @mcp.tool()
    async def toggle(
        simulator: Optional[str] = Field(default=None, description="Simulator UDID"),
        element: str = Field(description="Accessibility ID of the switch/segment to toggle"),
        value: Optional[int] = Field(default=None, description="Target segment index (for segmented controls)"),
    ) -> str:
        """Toggle a UISwitch or UISegmentedControl by accessibility ID.
        For switches: flips on/off. For segments: advances to next or jumps to specified index.
        Shows screen state after toggling."""
        params: dict = {"element": element}
        if value is not None:
            params["value"] = value
        return await act_and_look(simulator, "toggle", params)

    @mcp.tool()
    async def read_element(
        simulator: Optional[str] = Field(default=None, description="Simulator UDID"),
        element: str = Field(description="Accessibility ID of the element to read"),
    ) -> str:
        """Read an element's current value, type, and state by accessibility ID.
        Returns detailed info: text content, enabled/disabled, selected state, frame, etc."""
        return await resolve_and_send(simulator, "read", {"element": element})

    @mcp.tool()
    async def tree(
        simulator: Optional[str] = Field(default=None, description="Simulator UDID"),
        depth: Optional[int] = Field(default=None, description="Max tree depth (default: 50, max: 50)"),
        element: Optional[str] = Field(default=None, description="Scope to subtree of this accessibility ID"),
    ) -> str:
        """Dump UIView hierarchy for deep debugging. Full view tree with class, frame, accessibility info.
        Warning: view tree can be large — use depth limit or scope to a subtree."""
        params: dict = {}
        if depth is not None:
            params["depth"] = depth
        if element:
            params["element"] = element
        return await resolve_and_send(simulator, "tree", params)

    @mcp.tool()
    async def push(
        simulator: Optional[str] = Field(default=None, description="Simulator UDID"),
        action: Optional[str] = Field(default=None, description="Action: deliver (default), pending, clear"),
        title: Optional[str] = Field(default=None, description="Notification title"),
        body: Optional[str] = Field(default=None, description="Notification body text"),
        data: Optional[str] = Field(default=None, description="JSON userInfo payload for deeplink routing (e.g. '{\"type\":\"walk_summary\"}')"),
    ) -> str:
        """Simulate push notifications — deliver, list pending, or clear all.
        Delivered notifications appear like real remote pushes. Include data payload to test deeplink routing."""
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
        return await resolve_and_send(simulator, "push", params)

    @mcp.tool()
    async def status(
        simulator: Optional[str] = Field(default=None, description="Simulator UDID"),
        memory: bool = Field(default=False, description="Include process memory stats (resident size, virtual size, footprint)"),
        memory_detail: bool = Field(default=False, description="Include detailed VM breakdown (internal, compressed, purgeable)"),
    ) -> str:
        """Get device, app, and Pepper server info — bundle ID, version, port, connections, current screen.
        Add memory=true for process memory stats, or memory_detail=true for full VM breakdown."""
        result = await resolve_and_send(simulator, "status")
        if memory or memory_detail:
            mem_params: dict = {}
            if memory_detail:
                mem_params["action"] = "vm"
            mem_result = await resolve_and_send(simulator, "memory", mem_params)
            result += f"\n\n--- Memory ---\n{mem_result}"
        return result

    @mcp.tool()
    async def highlight(
        simulator: Optional[str] = Field(default=None, description="Simulator UDID"),
        text: Optional[str] = Field(default=None, description="Highlight element by text label"),
        frame: Optional[str] = Field(default=None, description="Highlight a frame: 'x,y,width,height'"),
        color: Optional[str] = Field(default=None, description="Color name (blue/green/red/yellow/purple) or hex (#ff0000)"),
        label: Optional[str] = Field(default=None, description="Label text to show on the highlight"),
        duration: Optional[float] = Field(default=None, description="How long to show in seconds (default: 0.8)"),
        clear: bool = Field(default=False, description="Clear all highlights"),
    ) -> str:
        """Draw a colored border around an element for visual debugging.
        Highlights appear as real UIViews — visible in recordings.
        Use clear=true to remove all highlights."""
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
        return await resolve_and_send(simulator, "highlight", params)

    @mcp.tool()
    async def orientation(
        simulator: Optional[str] = Field(default=None, description="Simulator UDID"),
        value: Optional[str] = Field(default=None, description="Target orientation: portrait, landscape_left, landscape_right, portrait_upside_down"),
    ) -> str:
        """Get or set device orientation. Omit value to query current orientation."""
        params: dict = {}
        if value:
            params["value"] = value
        return await resolve_and_send(simulator, "orientation", params)

    @mcp.tool()
    async def locale(
        simulator: Optional[str] = Field(default=None, description="Simulator UDID"),
        action: Optional[str] = Field(default=None, description="Action: current (default), set, reset, lookup, languages"),
        language: Optional[str] = Field(default=None, description="Language code for set/lookup (e.g. 'es', 'ja')"),
        region: Optional[str] = Field(default=None, description="Region code for set (e.g. 'JP', 'US')"),
        key: Optional[str] = Field(default=None, description="Localization key to look up (for lookup action)"),
    ) -> str:
        """Override app locale, look up localized strings, or list available languages.
        Useful for testing localization without changing simulator settings."""
        params: dict = {}
        if action:
            params["action"] = action
        if language:
            params["language"] = language
        if region:
            params["region"] = region
        if key:
            params["key"] = key
        return await resolve_and_send(simulator, "locale", params)

    @mcp.tool()
    async def gesture(
        simulator: Optional[str] = Field(default=None, description="Simulator UDID"),
        type: str = Field(description="Gesture type: pinch or rotate"),
        start_distance: Optional[int] = Field(default=None, description="Starting pinch distance in points (for pinch)"),
        end_distance: Optional[int] = Field(default=None, description="Ending pinch distance in points (for pinch)"),
        angle: Optional[float] = Field(default=None, description="Rotation angle in degrees (for rotate)"),
        center_x: Optional[float] = Field(default=None, description="Center X coordinate (defaults to screen center)"),
        center_y: Optional[float] = Field(default=None, description="Center Y coordinate (defaults to screen center)"),
    ) -> str:
        """Perform multi-touch gestures — pinch to zoom or rotate.
        For pinch: start_distance > end_distance = zoom out, end_distance > start_distance = zoom in.
        For rotate: specify angle in degrees.
        Center defaults to screen center — set center_x/center_y to target a specific view.

        Known limitation: pinch may not work on views with custom gesture recognizers
        (e.g. Google Maps GMSMapView). If pinch doesn't change state, try alternative
        approaches: defaults (set a debug zoom key), vars_inspect (mutate a ViewModel
        property), or add a temporary debug bridge in app code.

        Shows screen state after the gesture."""
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
        return await act_and_look(simulator, "gesture", params)

    @mcp.tool()
    async def hook(
        simulator: Optional[str] = Field(default=None, description="Simulator UDID"),
        action: str = Field(default="list", description="Action: install, remove, remove_all, list, log, clear"),
        class_name: Optional[str] = Field(default=None, description="ObjC class name (for install, e.g. 'UIViewController')"),
        method: Optional[str] = Field(default=None, description="ObjC method name (for install, e.g. 'viewDidAppear:')"),
        class_method: bool = Field(default=False, description="Hook class method (+) instead of instance method (-)"),
        hook_id: Optional[str] = Field(default=None, description="Hook ID (for remove, log, clear)"),
        limit: Optional[int] = Field(default=None, description="Max log entries to return (default: 50)"),
    ) -> str:
        """Hook ObjC methods at runtime to log invocations. Transparent — original method is called through.

        Examples:
          hook action=install class_name=UIViewController method="viewDidAppear:"
          hook action=log hook_id=hook_1 limit=20
          hook action=list
          hook action=remove hook_id=hook_1

        Supports: void/object/BOOL return × 0-3 object args, void + 1 BOOL arg.
        Covers ~90% of useful targets: lifecycle, delegate, network, analytics methods.
        """
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
        return await resolve_and_send(simulator, "hook", params)

    @mcp.tool()
    async def find(
        simulator: Optional[str] = Field(default=None, description="Simulator UDID"),
        predicate: str = Field(description="NSPredicate format string (e.g. \"label CONTAINS 'Save' AND type == 'button'\")"),
        action: str = Field(default="list", description="Action: list (default), first, count"),
        limit: Optional[int] = Field(default=None, description="Max results to return (default: 50)"),
    ) -> str:
        """Query on-screen elements using NSPredicate expressions. Native iOS predicate syntax.

        Available properties:
          label (String), type (String: button/toggle/text/searchField/tab/etc),
          className (String), interactive (Bool), enabled (Bool), hitReachable (Bool),
          visible (Float), heuristic (String), iconName (String), traits ([String]),
          x/y/width/height/centerX/centerY (Double), viewController (String),
          presentationContext (String: root/sheet/modal/navigation)

        Examples:
          "label CONTAINS 'Save'"
          "type == 'button' AND hitReachable == true"
          "'selected' IN traits"
          "label LIKE '*Settings*' AND interactive == true"
          "centerY > 400 AND type == 'toggle'"
          "viewController == 'ProfileViewController'"
        """
        params: dict = {"predicate": predicate, "action": action}
        if limit is not None:
            params["limit"] = limit
        return await resolve_and_send(simulator, "find", params)

    @mcp.tool()
    async def flags(
        simulator: Optional[str] = Field(default=None, description="Simulator UDID"),
        action: str = Field(default="list", description="Action: list, get, set, clear"),
        key: Optional[str] = Field(default=None, description="Feature flag key"),
        value: Optional[str] = Field(default=None, description="Value to set (true/false for bools, or string/int)"),
    ) -> str:
        """Override feature flags via network response interception. Set a flag, then deploy to apply.

        Mechanism: Intercepts the network response that delivers feature flags and modifies the
        payload before the app processes it. The app receives already-modified data and stores it
        through its normal code path — no timing races, no ivar hacking.

        Workflow:
          1. flags action=set key="some_flag" value="true"
          2. deploy  (restarts app — first flag fetch is intercepted with your override)
          3. look visual=true screenshot_quality=high  (verify + capture)

        Overrides persist across deploys until explicitly cleared.
        - list: show all active overrides + network override status
        - get: read a specific flag's override and service value
        - set: override a flag (intercepts server flag response on next deploy)
        - clear: remove one override (key=...) or all overrides (no key)"""
        params: dict = {"action": action}
        if key:
            params["key"] = key
        if value is not None:
            params["value"] = try_parse_json(value)
        return await resolve_and_send(simulator, "flags", params)

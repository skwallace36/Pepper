"""Navigation and interaction tool definitions for Pepper MCP.

Tool definitions for: look, tap, scroll, input_text, navigate, back, dismiss,
swipe, screen, scroll_to, dismiss_keyboard, snapshot, diff.
"""

import asyncio
import base64
import json
from mcp.types import ImageContent, TextContent
from mcp_screenshot import capture_screenshot, capture_screenshot_inprocess
from pepper_common import discover_instance
from pepper_format import format_look, format_look_compact
from pydantic import Field


def register_nav_tools(mcp, send_command, resolve_and_send, act_and_look):
    """Register navigation/interaction tools on the given MCP server.

    Args:
        mcp: FastMCP server instance.
        send_command: async (port, cmd, params?, timeout?) -> dict
        resolve_and_send: async (simulator, cmd, params?, timeout?) -> str
        act_and_look: async (simulator, cmd, params?, timeout?) -> str
    """

    @mcp.tool()
    async def look(
        simulator: str | None = Field(default=None, description="Simulator UDID (optional if only one sim running)"),
        raw: bool = Field(default=False, description="Return raw JSON instead of formatted summary"),
        compact: bool = Field(default=False, description="Slim output for agent sessions: omits coordinates/frames, shows only changed elements vs previous call, reduces context by ~60-70%"),
        visual: bool = Field(default=False, description="Include a simulator screenshot alongside the structured data"),
        screenshot_quality: str = Field(default="standard", description="Screenshot quality: 'standard' (70% JPEG) or 'high' (95% JPEG, for PR validation)"),
        save_screenshot: str | None = Field(default=None, description="Save screenshot to this file path (in addition to returning it)"),
    ) -> list:
        """See what's on screen — all interactive elements with tap commands, plus visible text.
        Use compact=true for agent sessions — omits coordinates, diffs against last call, cuts context ~60-70%.
        Use raw=true when you need coordinates, frames, or scroll context.
        Use visual=true to include a screenshot for visual validation.
        Use screenshot_quality='high' + save_screenshot='/tmp/foo.jpg' for PR validation screenshots."""
        try:
            host, port, udid = discover_instance(simulator)
        except RuntimeError as e:
            return [TextContent(type="text", text=str(e))]

        if visual or save_screenshot:
            # Run introspect and screenshot in parallel.
            # Try fast in-process capture first; fall back to simctl if unavailable.
            quality = screenshot_quality if screenshot_quality in ("standard", "high") else "standard"
            introspect_task = asyncio.create_task(
                send_command(port, "look", {}, host=host)
            )
            screenshot_task = asyncio.create_task(
                capture_screenshot_inprocess(send_command, port, quality, host=host)
            )
            resp, screenshot_b64 = await asyncio.gather(introspect_task, screenshot_task)
            # Fallback to simctl if in-process capture failed
            if screenshot_b64 is None:
                screenshot_b64 = await capture_screenshot(udid, quality=quality)
        else:
            resp = await send_command(port, "look", {}, host=host)
            screenshot_b64 = None

        if raw:
            text = json.dumps(resp, indent=2)
        elif compact:
            text = format_look_compact(resp)
        else:
            text = format_look(resp)

        result = [TextContent(type="text", text=text)]
        if screenshot_b64:
            result.append(ImageContent(type="image", data=screenshot_b64, mimeType="image/jpeg"))
            # Save to disk if requested
            if save_screenshot:
                try:
                    with open(save_screenshot, 'wb') as f:
                        f.write(base64.b64decode(screenshot_b64))
                    result[0] = TextContent(type="text", text=f"{text}\n\n[Screenshot saved to {save_screenshot}]")
                except OSError as e:
                    result[0] = TextContent(type="text", text=f"{text}\n\n[Screenshot save failed: {e}]")
        return result

    @mcp.tool()
    async def screenshot(
        simulator: str | None = Field(default=None, description="Simulator UDID"),
        element: str | None = Field(default=None, description="Accessibility ID of a specific view to capture"),
        text: str | None = Field(default=None, description="Visible text/label of a specific view to capture"),
        quality: str = Field(default="standard", description="'standard' (70% JPEG) or 'high' (95% JPEG)"),
        save_to: str | None = Field(default=None, description="Save screenshot to this file path"),
    ) -> list:
        """Capture a screenshot in-process (faster than simctl). Supports per-view snapshots.
        Omit element/text to capture the full screen.
        Specify element or text to capture just that view."""
        try:
            host, port, udid = discover_instance(simulator)
        except RuntimeError as e:
            return [TextContent(type="text", text=str(e))]

        q = quality if quality in ("standard", "high") else "standard"
        screenshot_b64 = await capture_screenshot_inprocess(
            send_command, port, q, element=element, text=text, host=host,
        )
        if screenshot_b64 is None:
            # Fallback to simctl for full-screen only (no per-view support)
            if element is None and text is None:
                screenshot_b64 = await capture_screenshot(udid, q)
            if screenshot_b64 is None:
                return [TextContent(type="text", text="Screenshot capture failed")]

        result: list = []
        scope = "element" if (element or text) else "fullscreen"
        result.append(ImageContent(type="image", data=screenshot_b64, mimeType="image/jpeg"))

        if save_to:
            try:
                with open(save_to, 'wb') as f:
                    f.write(base64.b64decode(screenshot_b64))
                result.append(TextContent(type="text", text=f"[{scope} screenshot saved to {save_to}]"))
            except OSError as e:
                result.append(TextContent(type="text", text=f"[Save failed: {e}]"))
        else:
            result.append(TextContent(type="text", text=f"[{scope} screenshot captured]"))
        return result

    @mcp.tool()
    async def tap(
        simulator: str | None = Field(default=None, description="Simulator UDID"),
        text: str | None = Field(default=None, description="Tap element by visible text/label"),
        icon: str | None = Field(default=None, description="Tap element by icon name (e.g. 'gift-fill-icon')"),
        heuristic: str | None = Field(default=None, description="Tap element by heuristic (e.g. 'menu_button')"),
        point: str | None = Field(default=None, description="Tap at coordinates 'x,y' (e.g. '200,400')"),
        double: bool = Field(default=False, description="Double-tap (two rapid taps for zoom, like, etc.)"),
        duration: float | None = Field(default=None, description="Hold duration in seconds. Use >0.5 for long press."),
    ) -> str:
        """Tap an element on screen. Specify exactly one of: text, icon, heuristic, or point.
        Add double=true for double-tap, or duration=1.0 for long press.
        Automatically shows screen state after the tap so you can verify it worked."""
        params = {}
        if text:
            params["text"] = text
        elif icon:
            params["icon_name"] = icon
        elif heuristic:
            params["heuristic"] = heuristic
        elif point:
            try:
                parts = point.split(",")
                params["point"] = {"x": float(parts[0]), "y": float(parts[1])}
            except (ValueError, IndexError):
                return "Error: point must be 'x,y' (e.g. '200,400')"
        else:
            return "Error: specify one of text, icon, heuristic, or point"
        if double:
            params["double"] = True
        if duration is not None:
            params["duration"] = duration
        return await act_and_look(simulator, "tap", params)

    @mcp.tool()
    async def scroll(
        simulator: str | None = Field(default=None, description="Simulator UDID"),
        direction: str = Field(description="Scroll direction: up, down, left, right"),
        amount: int | None = Field(default=None, description="Scroll amount in points"),
    ) -> str:
        """Scroll the screen in a direction. Automatically shows screen state after scrolling."""
        params: dict = {"direction": direction}
        if amount is not None:
            params["amount"] = amount
        return await act_and_look(simulator, "scroll", params)

    @mcp.tool()
    async def input_text(
        simulator: str | None = Field(default=None, description="Simulator UDID"),
        element_id: str = Field(description="Accessibility ID of the text field"),
        value: str = Field(description="Text to type"),
    ) -> str:
        """Type text into a text field. Automatically shows screen state after input."""
        return await act_and_look(simulator, "input", {"id": element_id, "value": value})

    @mcp.tool()
    async def navigate(
        simulator: str | None = Field(default=None, description="Simulator UDID"),
        deeplink: str | None = Field(default=None, description="Deep link destination (e.g. 'home', 'settings')"),
        tab: int | None = Field(default=None, description="Tab index to switch to"),
        list_deeplinks: bool = Field(default=False, description="List all available deep link destinations"),
        category: str | None = Field(default=None, description="Filter deep link list by category"),
    ) -> str:
        """Navigate to a screen via deep link or tab switch. Shows screen state after navigation.
        Use list_deeplinks=true to see all available destinations."""
        if list_deeplinks:
            params: dict = {}
            if category:
                params["category"] = category
            return await resolve_and_send(simulator, "deeplinks", params)
        params = {}
        if deeplink:
            params["deeplink"] = deeplink
        elif tab is not None:
            params["tab"] = tab
        else:
            return "Error: specify deeplink, tab, or list_deeplinks=true"
        return await act_and_look(simulator, "navigate", params)

    @mcp.tool()
    async def back(
        simulator: str | None = Field(default=None, description="Simulator UDID"),
    ) -> str:
        """Go back / dismiss the current screen. Automatically shows screen state after going back."""
        return await act_and_look(simulator, "back")

    @mcp.tool()
    async def dismiss(
        simulator: str | None = Field(default=None, description="Simulator UDID"),
    ) -> str:
        """Dismiss the topmost modal/sheet. Automatically shows screen state after dismissal."""
        return await act_and_look(simulator, "dismiss")

    @mcp.tool()
    async def swipe(
        simulator: str | None = Field(default=None, description="Simulator UDID"),
        direction: str = Field(description="Swipe direction: up, down, left, right"),
    ) -> str:
        """Swipe in a direction (like a quick flick, vs scroll which is a slow drag). Shows screen state after."""
        return await act_and_look(simulator, "swipe", {"direction": direction})

    @mcp.tool()
    async def screen(
        simulator: str | None = Field(default=None, description="Simulator UDID"),
    ) -> str:
        """Get the current screen name and view controller."""
        return await resolve_and_send(simulator, "screen")

    @mcp.tool()
    async def scroll_to(
        simulator: str | None = Field(default=None, description="Simulator UDID"),
        text: str = Field(description="Text to scroll to (scrolls until this text is visible on screen)"),
        direction: str = Field(default="down", description="Scroll direction: up, down, left, right"),
        max_scrolls: int | None = Field(default=None, description="Max scroll attempts (default: 10)"),
    ) -> str:
        """Scroll incrementally until target text appears on screen. Combines scroll + visibility polling.
        Automatically shows screen state after finding the element."""
        params: dict = {"text": text, "direction": direction}
        if max_scrolls is not None:
            params["max_scrolls"] = max_scrolls
        return await act_and_look(simulator, "scroll_to", params, timeout=15)

    @mcp.tool()
    async def dismiss_keyboard(
        simulator: str | None = Field(default=None, description="Simulator UDID"),
    ) -> str:
        """Dismiss the on-screen keyboard by resigning first responder. Shows screen state after."""
        return await act_and_look(simulator, "dismiss_keyboard")

    @mcp.tool()
    async def snapshot(
        simulator: str | None = Field(default=None, description="Simulator UDID"),
        action: str = Field(default="save", description="Action: 'save' (capture baseline), 'diff' (compare to baseline), 'list', 'delete', 'clear'"),
        name: str = Field(default="default", description="Snapshot name for save/diff/delete"),
        ignore_transient: bool = Field(default=False, description="Ignore volatile/transient text elements (timestamps, animation frames) in diffs"),
        assert_no_diff: bool = Field(default=False, description="Return error if any diff is detected (for regression testing)"),
    ) -> str:
        """Capture screen state as a named snapshot, then diff against it after actions.

        Workflow: snapshot action=save name=baseline → perform actions → snapshot action=diff name=baseline.
        Returns semantic diff: added/removed/changed elements and text.
        Use assert_no_diff=true to fail if state changed (regression testing)."""
        return await resolve_and_send(simulator, "snapshot", {
            "action": action,
            "name": name,
            "ignore_transient": ignore_transient,
            "assert_no_diff": assert_no_diff,
        })

    @mcp.tool()
    async def diff(
        simulator: str | None = Field(default=None, description="Simulator UDID"),
        action: str = Field(default="start", description="Action: 'start' (capture baseline), 'show' (compare to baseline), 'clear' (discard baseline)"),
    ) -> str:
        """Quick view hierarchy diff — show what changed between two look snapshots.

        Workflow: diff action=start → perform actions (tap, scroll, etc.) → diff action=show.
        Returns only added/removed/changed elements — much smaller than a full look call.
        Useful for verifying that an action actually changed the UI."""
        return await resolve_and_send(simulator, "diff", {"action": action})

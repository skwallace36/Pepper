"""Navigation and interaction tool definitions for Pepper MCP.

Tool definitions for: look, tap, scroll, input_text, navigate, back, dismiss,
swipe, screen, scroll_to, dismiss_keyboard.
"""

import asyncio
import base64
import json
from typing import Optional

from mcp.types import TextContent, ImageContent
from pydantic import Field

from mcp_screenshot import capture_screenshot
from pepper_common import discover_simulator
from pepper_format import format_look


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
        simulator: Optional[str] = Field(default=None, description="Simulator UDID (optional if only one sim running)"),
        raw: bool = Field(default=False, description="Return raw JSON instead of formatted summary"),
        visual: bool = Field(default=False, description="Include a simulator screenshot alongside the structured data"),
        screenshot_quality: str = Field(default="standard", description="Screenshot quality: 'standard' (70% JPEG) or 'high' (95% JPEG, for PR validation)"),
        save_screenshot: Optional[str] = Field(default=None, description="Save screenshot to this file path (in addition to returning it)"),
    ) -> list:
        """See what's on screen — all interactive elements with tap commands, plus visible text.
        Use raw=true when you need coordinates, frames, or scroll context.
        Use visual=true to include a screenshot for visual validation.
        Use screenshot_quality='high' + save_screenshot='/tmp/foo.jpg' for PR validation screenshots."""
        try:
            udid, port = discover_simulator(simulator)
        except RuntimeError as e:
            return [TextContent(type="text", text=str(e))]

        if visual or save_screenshot:
            # Run introspect and screenshot in parallel
            quality = screenshot_quality if screenshot_quality in ("standard", "high") else "standard"
            introspect_task = asyncio.create_task(
                send_command(port, "look", {})
            )
            screenshot_task = asyncio.create_task(capture_screenshot(udid, quality=quality))
            resp, screenshot_b64 = await asyncio.gather(introspect_task, screenshot_task)
        else:
            resp = await send_command(port, "look", {})
            screenshot_b64 = None

        if raw:
            text = json.dumps(resp, indent=2)
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
                except Exception as e:
                    result[0] = TextContent(type="text", text=f"{text}\n\n[Screenshot save failed: {e}]")
        return result

    @mcp.tool()
    async def tap(
        simulator: Optional[str] = Field(default=None, description="Simulator UDID"),
        text: Optional[str] = Field(default=None, description="Tap element by visible text/label"),
        icon: Optional[str] = Field(default=None, description="Tap element by icon name (e.g. 'gift-fill-icon')"),
        heuristic: Optional[str] = Field(default=None, description="Tap element by heuristic (e.g. 'menu_button')"),
        point: Optional[str] = Field(default=None, description="Tap at coordinates 'x,y' (e.g. '200,400')"),
        double: bool = Field(default=False, description="Double-tap (two rapid taps for zoom, like, etc.)"),
        duration: Optional[float] = Field(default=None, description="Hold duration in seconds. Use >0.5 for long press."),
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
        simulator: Optional[str] = Field(default=None, description="Simulator UDID"),
        direction: str = Field(description="Scroll direction: up, down, left, right"),
        amount: Optional[int] = Field(default=None, description="Scroll amount in points"),
    ) -> str:
        """Scroll the screen in a direction. Automatically shows screen state after scrolling."""
        params = {"direction": direction}
        if amount is not None:
            params["amount"] = amount
        return await act_and_look(simulator, "scroll", params)

    @mcp.tool()
    async def input_text(
        simulator: Optional[str] = Field(default=None, description="Simulator UDID"),
        element_id: str = Field(description="Accessibility ID of the text field"),
        value: str = Field(description="Text to type"),
    ) -> str:
        """Type text into a text field. Automatically shows screen state after input."""
        return await act_and_look(simulator, "input", {"id": element_id, "value": value})

    @mcp.tool()
    async def navigate(
        simulator: Optional[str] = Field(default=None, description="Simulator UDID"),
        deeplink: Optional[str] = Field(default=None, description="Deep link destination (e.g. 'home', 'settings')"),
        tab: Optional[int] = Field(default=None, description="Tab index to switch to"),
        list_deeplinks: bool = Field(default=False, description="List all available deep link destinations"),
        category: Optional[str] = Field(default=None, description="Filter deep link list by category"),
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
        simulator: Optional[str] = Field(default=None, description="Simulator UDID"),
    ) -> str:
        """Go back / dismiss the current screen. Automatically shows screen state after going back."""
        return await act_and_look(simulator, "back")

    @mcp.tool()
    async def dismiss(
        simulator: Optional[str] = Field(default=None, description="Simulator UDID"),
    ) -> str:
        """Dismiss the topmost modal/sheet. Automatically shows screen state after dismissal."""
        return await act_and_look(simulator, "dismiss")

    @mcp.tool()
    async def swipe(
        simulator: Optional[str] = Field(default=None, description="Simulator UDID"),
        direction: str = Field(description="Swipe direction: up, down, left, right"),
    ) -> str:
        """Swipe in a direction (like a quick flick, vs scroll which is a slow drag). Shows screen state after."""
        return await act_and_look(simulator, "swipe", {"direction": direction})

    @mcp.tool()
    async def screen(
        simulator: Optional[str] = Field(default=None, description="Simulator UDID"),
    ) -> str:
        """Get the current screen name and view controller."""
        return await resolve_and_send(simulator, "screen")

    @mcp.tool()
    async def scroll_to(
        simulator: Optional[str] = Field(default=None, description="Simulator UDID"),
        text: str = Field(description="Text to scroll to (scrolls until this text is visible on screen)"),
        direction: str = Field(default="down", description="Scroll direction: up, down, left, right"),
        max_scrolls: Optional[int] = Field(default=None, description="Max scroll attempts (default: 10)"),
    ) -> str:
        """Scroll incrementally until target text appears on screen. Combines scroll + visibility polling.
        Automatically shows screen state after finding the element."""
        params: dict = {"text": text, "direction": direction}
        if max_scrolls is not None:
            params["max_scrolls"] = max_scrolls
        return await act_and_look(simulator, "scroll_to", params, timeout=15)

    @mcp.tool()
    async def dismiss_keyboard(
        simulator: Optional[str] = Field(default=None, description="Simulator UDID"),
    ) -> str:
        """Dismiss the on-screen keyboard by resigning first responder. Shows screen state after."""
        return await act_and_look(simulator, "dismiss_keyboard")

"""Navigation and interaction tool definitions for Pepper MCP.

Tool definitions for: look, tap, scroll, input_text, navigate, back, dismiss,
swipe, screen, scroll_to (deprecated), dismiss_keyboard, snapshot, diff.
"""

from __future__ import annotations

import asyncio
import base64
import json
import logging

from mcp.types import ImageContent, TextContent
from pydantic import Field

from .mcp_screenshot import capture_screenshot, capture_screenshot_inprocess
from .pepper_ax import detect_dialog as _ax_detect
from .pepper_commands import (
    CMD_BACK,
    CMD_DEEPLINKS,
    CMD_DIFF,
    CMD_DISMISS,
    CMD_DISMISS_KEYBOARD,
    CMD_INPUT,
    CMD_LOOK,
    CMD_NAVIGATE,
    CMD_SCREEN,
    CMD_SCROLL,
    CMD_SCROLL_TO,
    CMD_SNAPSHOT,
    CMD_SWIPE,
    CMD_TAP,
)
from .pepper_common import discover_instance, json_dumps
from .pepper_format import format_look, format_look_compact, format_look_slim

_logger = logging.getLogger(__name__)


def register_nav_tools(mcp, send_command, resolve_and_send, act_and_look):
    """Register navigation/interaction tools on the given MCP server.

    Args:
        mcp: FastMCP server instance.
        send_command: async (port, cmd, params?, timeout?) -> dict
        resolve_and_send: async (simulator, cmd, params?, timeout?) -> dict
        act_and_look: async (simulator, cmd, params?, timeout?) -> str
    """

    @mcp.tool()
    async def look(
        simulator: str | None = Field(default=None, description="Simulator UDID (optional if only one sim running)"),
        scope: str | None = Field(
            default=None,
            description="Filter to elements inside a container. Pass an accessibility identifier or visible label (e.g. scope='Steps', scope='tab_bar'). Uses element resolution — same matching as tap/read_element.",
        ),
        region: str | None = Field(
            default=None,
            description="Filter to elements in a y-range. Pass 'minY-maxY' (e.g. region='390-532'). For exact box use raw JSON: {\"x\":0,\"y\":390,\"w\":390,\"h\":142}.",
        ),
        raw: bool = Field(default=False, description="Return raw JSON instead of formatted summary"),
        slim: bool = Field(
            default=False,
            description="Stateless flat list: every call returns all elements with tap commands, no y-coordinates or group headers. Best for one-shot observation when you need the full picture.",
        ),
        compact: bool = Field(
            default=False,
            description="Stateful diff: first call returns all elements with tap commands; subsequent calls show only added/changed/removed elements. Best for monitoring — call repeatedly and only see what changed. Resets on screen change.",
        ),
        ocr: bool = Field(
            default=False,
            description="Run OCR on the screen to find text not in the accessibility tree. Adds ~60-120ms. OCR-only results shown in a separate section.",
        ),
        visual: bool = Field(default=False, description="Include a simulator screenshot alongside the structured data"),
        screenshot_quality: str = Field(
            default="standard",
            description="Screenshot quality: 'standard' (70% JPEG) or 'high' (95% JPEG, for PR validation)",
        ),
        save_screenshot: str | None = Field(
            default=None, description="Save screenshot to this file path (in addition to returning it)"
        ),
        detail: str = Field(
            default="summary",
            description="Detail level: 'summary' (default) returns element names/types/tap commands — minimal tokens for agent use. 'full' includes frames, traits, heuristics, scroll_context — use when debugging layout.",
        ),
    ) -> list:
        """Primary observation tool — returns all interactive elements with tap commands, plus visible text. Call before acting to know what's available."""
        try:
            host, port, udid = discover_instance(simulator)
        except RuntimeError as e:
            return [TextContent(type="text", text=str(e))]

        look_params: dict = {}
        if scope:
            look_params["scope"] = scope
        if region:
            # Try to parse as JSON dict first (e.g. '{"x":0,"y":390,"w":390,"h":142}')
            if region.strip().startswith("{"):
                try:
                    look_params["region"] = json.loads(region)
                except json.JSONDecodeError:
                    look_params["region"] = region
            else:
                look_params["region"] = region
        if ocr:
            look_params["ocr"] = True
        if detail == "full":
            look_params["detail"] = "full"

        # Always run the AX probe in parallel with the dylib command.
        # It checks for SpringBoard dialogs (permission prompts, etc.) that
        # the in-process dylib cannot see.
        ax_task = asyncio.ensure_future(asyncio.get_running_loop().run_in_executor(None, _ax_detect))

        if visual or save_screenshot:
            # Run introspect and screenshot in parallel.
            # Try fast in-process capture first; fall back to simctl if unavailable.
            quality = screenshot_quality if screenshot_quality in ("standard", "high") else "standard"
            introspect_task = asyncio.create_task(send_command(port, CMD_LOOK, look_params, host=host, timeout=20))
            screenshot_task = asyncio.create_task(capture_screenshot_inprocess(send_command, port, quality, host=host))
            resp, screenshot_b64 = await asyncio.gather(introspect_task, screenshot_task)
            # Fallback to simctl if in-process capture failed
            if screenshot_b64 is None:
                screenshot_b64 = await capture_screenshot(udid, quality=quality)
        else:
            resp = await send_command(port, CMD_LOOK, look_params, host=host, timeout=20)
            screenshot_b64 = None

        # Collect AX probe result (fast — should already be done).
        try:
            ax_result = await asyncio.wait_for(ax_task, timeout=0.3)
        except (asyncio.TimeoutError, Exception) as exc:
            _logger.debug("AX probe skipped: %s", exc)
            ax_result = None

        # Inject SpringBoard dialog into the response so all formatters
        # (format_look, format_look_slim, format_look_compact) surface it
        # through existing system_dialog_blocking handling.
        data = resp.get("data", resp)
        if ax_result and ax_result.get("detected") and not data.get("system_dialog_blocking"):
            data["system_dialog_blocking"] = {
                "warning": "springboard_dialog_detected",
                "description": "A SpringBoard system dialog is overlaying the app. Use dialog dismiss_system to handle it.",
                "dialogs": [{"title": "System Dialog", "buttons": ax_result.get("buttons", [])}],
                "suggested_actions": [
                    "dialog dismiss_system",
                    "dialog detect_system",
                ],
            }

        if raw:
            text = json_dumps(resp)
        elif slim:
            text = format_look_slim(resp)
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
                    with open(save_screenshot, "wb") as f:
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
        """Capture a visual screenshot without structured element data. Prefer look with visual=true if you also need element data."""
        try:
            host, port, udid = discover_instance(simulator)
        except RuntimeError as e:
            return [TextContent(type="text", text=str(e))]

        q = quality if quality in ("standard", "high") else "standard"
        screenshot_b64 = await capture_screenshot_inprocess(
            send_command,
            port,
            q,
            element=element,
            text=text,
            host=host,
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
                with open(save_to, "wb") as f:
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
        debug: bool = Field(
            default=False,
            description="Include tap diagnostics: hit-test result, gesture recognizers, responder chain, and overlapping views. Use when a tap doesn't produce the expected result.",
        ),
    ) -> list:
        """Tap an interactive element. Specify exactly one of: text, icon, heuristic, or point. Shows screen state after."""
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
                return [TextContent(type="text", text="Error: point must be x,y (e.g. 200,400)")]
        else:
            return [TextContent(type="text", text="Error: specify one of text, icon, heuristic, or point")]
        if double:
            params["double"] = True
        if duration is not None:
            params["duration"] = duration
        if debug:
            params["debug"] = True
        return await act_and_look(simulator, CMD_TAP, params)

    @mcp.tool()
    async def scroll(
        simulator: str | None = Field(default=None, description="Simulator UDID"),
        direction: str = Field(default="down", description="Scroll direction: up, down, left, right"),
        amount: int | None = Field(default=None, description="Scroll amount in points"),
        target: str | None = Field(default=None, description="Text to scroll to — scrolls incrementally until this text is visible. When set, direction defaults to 'down'."),
        max_scrolls: int | None = Field(default=None, description="Max scroll attempts when using target (default: 10)"),
    ) -> list:
        """Scroll by direction, or pass target to scroll until specific text is visible. Shows screen state after."""
        if target:
            params: dict = {"text": target, "direction": direction}
            if max_scrolls is not None:
                params["max_scrolls"] = max_scrolls
            return await act_and_look(simulator, CMD_SCROLL_TO, params, timeout=15)
        params = {"direction": direction}
        if amount is not None:
            params["amount"] = amount
        return await act_and_look(simulator, CMD_SCROLL, params)

    @mcp.tool()
    async def input_text(
        simulator: str | None = Field(default=None, description="Simulator UDID"),
        element_id: str | None = Field(
            default=None,
            description="Accessibility ID of the text field. If omitted, types into the focused field or first available text field.",
        ),
        text: str | None = Field(
            default=None,
            description="Find text field by visible text, placeholder, or label (e.g. 'Search', 'Email'). Same matching as tap's text parameter.",
        ),
        value: str = Field(description="Text to type"),
        clear: bool = Field(default=False, description="Clear existing text before typing"),
        submit: bool = Field(default=False, description="Submit/return after typing"),
    ) -> list:
        """Enter or replace text in a field. Focuses the field and types in one step — don't tap first. Shows screen state after."""
        params: dict = {"value": value}
        if element_id:
            params["element"] = element_id
        if text:
            params["text"] = text
        if clear:
            params["clear"] = True
        if submit:
            params["submit"] = True
        return await act_and_look(simulator, CMD_INPUT, params)

    @mcp.tool()
    async def navigate(
        simulator: str | None = Field(default=None, description="Simulator UDID"),
        deeplink: str | None = Field(default=None, description="Deep link destination (e.g. 'home', 'settings')"),
        tab: int | str | None = Field(default=None, description="Tab index (0-based) or tab name to switch to"),
        list_deeplinks: bool = Field(default=False, description="List all available deep link destinations"),
        category: str | None = Field(default=None, description="Filter deep link list by category"),
    ) -> list | str:
        """Jump to a specific screen via deeplink or switch tabs. Use list_deeplinks=true to see available destinations. Shows screen state after."""
        if list_deeplinks:
            params: dict = {}
            if category:
                params["category"] = category
            return json_dumps(await resolve_and_send(simulator, CMD_DEEPLINKS, params))
        params = {}
        if deeplink:
            params["deeplink"] = deeplink
        elif tab is not None:
            if isinstance(tab, int):
                params["tab"] = tab
            else:
                # String tab name — resolve via the "to" param which supports name lookup
                params["to"] = tab
        else:
            return [TextContent(type="text", text="Error: specify deeplink, tab, or list_deeplinks=true")]
        return await act_and_look(simulator, CMD_NAVIGATE, params)

    @mcp.tool()
    async def back(
        simulator: str | None = Field(default=None, description="Simulator UDID"),
    ) -> list:
        """Go back one screen in a navigation stack. For modals/sheets use dismiss; for jumping to a screen use navigate."""
        return await act_and_look(simulator, CMD_BACK)

    @mcp.tool()
    async def dismiss(
        simulator: str | None = Field(default=None, description="Simulator UDID"),
    ) -> list:
        """Close a modal, sheet, popover, or overlay. For navigation stack screens use back; for system dialogs use dialog."""
        return await act_and_look(simulator, CMD_DISMISS)

    @mcp.tool()
    async def swipe(
        simulator: str | None = Field(default=None, description="Simulator UDID"),
        direction: str = Field(description="Swipe direction: up, down, left, right"),
    ) -> list:
        """Fast flick gesture for paging, dismissing cards, or pull-to-refresh. Use scroll for slow content browsing instead. Shows screen state after."""
        return await act_and_look(simulator, CMD_SWIPE, {"direction": direction})

    @mcp.tool()
    async def screen(
        simulator: str | None = Field(default=None, description="Simulator UDID"),
    ) -> str:
        """Identify which screen is currently displayed. Returns screen name and view controller class — no element data."""
        return json_dumps(await resolve_and_send(simulator, CMD_SCREEN))

    @mcp.tool()
    async def scroll_to(
        simulator: str | None = Field(default=None, description="Simulator UDID"),
        text: str = Field(description="Text to scroll to (scrolls until this text is visible on screen)"),
        direction: str = Field(default="down", description="Scroll direction: up, down, left, right"),
        max_scrolls: int | None = Field(default=None, description="Max scroll attempts (default: 10)"),
    ) -> list:
        """Deprecated — use scroll with target param instead. Scrolls until text is visible."""
        _logger.info("scroll_to is deprecated — use scroll(target='%s') instead", text)
        return await scroll(simulator=simulator, direction=direction, target=text, max_scrolls=max_scrolls)

    @mcp.tool()
    async def dismiss_keyboard(
        simulator: str | None = Field(default=None, description="Simulator UDID"),
    ) -> list:
        """Dismiss the on-screen keyboard. Call after input_text when you need to tap elements the keyboard covers."""
        return await act_and_look(simulator, CMD_DISMISS_KEYBOARD)

    @mcp.tool()
    async def snapshot(
        simulator: str | None = Field(default=None, description="Simulator UDID"),
        action: str = Field(
            default="save",
            description="Action: 'save' (capture baseline), 'diff' (compare to baseline), 'list', 'delete', 'clear'",
        ),
        name: str = Field(default="default", description="Snapshot name for save/diff/delete"),
        ignore_transient: bool = Field(
            default=False, description="Ignore volatile/transient text elements (timestamps, animation frames) in diffs"
        ),
        assert_no_diff: bool = Field(
            default=False, description="Return error if any diff is detected (for regression testing)"
        ),
    ) -> str:
        """Capture screen state as a named snapshot, then diff against it later to see what changed."""
        return json_dumps(
            await resolve_and_send(
                simulator,
                CMD_SNAPSHOT,
                {
                    "action": action,
                    "name": name,
                    "ignore_transient": ignore_transient,
                    "assert_no_diff": assert_no_diff,
                },
            )
        )

    @mcp.tool()
    async def diff(
        simulator: str | None = Field(default=None, description="Simulator UDID"),
        action: str = Field(
            default="start",
            description="Action: 'start' (capture baseline), 'show' (compare to baseline), 'clear' (discard baseline)",
        ),
    ) -> str:
        """Quick view hierarchy diff — start a baseline, perform actions, then show to see only added/removed/changed elements."""
        return json_dumps(await resolve_and_send(simulator, CMD_DIFF, {"action": action}))

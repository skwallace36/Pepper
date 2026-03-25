"""Dialog tool definition for Pepper MCP.

Tool definitions for: dialog.
Includes system-dialog dismiss helper with simctl privacy grant + AX fallback.
"""
from __future__ import annotations

import asyncio
import json
import subprocess

from pepper_ax import detect_dialog as _ax_detect
from pepper_ax import find_and_dismiss_dialog as _ax_dismiss
from pepper_commands import CMD_DIALOG
from pepper_common import get_config, require_parse_json
from pydantic import Field

# Permission keywords found in dialog titles/messages → simctl permission names
_PERMISSION_KEYWORDS = {
    "photo": ["photos", "photos-add"],
    "camera": ["camera"],
    "microphone": ["microphone"],
    "contact": ["contacts"],
    "calendar": ["calendar"],
    "reminder": ["reminders"],
    "location": ["location-always", "location-when-in-use"],
    "notification": ["notifications"],
    "health": ["health"],
}

# All permissions to try when we can't infer the type
_ALL_PERMISSIONS = [
    "photos",
    "photos-add",
    "camera",
    "microphone",
    "contacts",
    "calendar",
    "reminders",
    "location-always",
    "location-when-in-use",
    "notifications",
    "health",
]

# Common permission dialog buttons in preference order
_PERMISSION_BUTTONS = [
    "Allow While Using App",
    "Allow Once",
    "Allow",
    "OK",
]


def _infer_permissions(text: str) -> list[str]:
    """Infer simctl permission names from dialog title/message text."""
    perms = []
    lower = text.lower()
    for keyword, permission_names in _PERMISSION_KEYWORDS.items():
        if keyword in lower:
            perms.extend(permission_names)
    return perms


async def _dismiss_system_dialog(simulator, resolve_and_send, resolve_simulator):
    """Detect and dismiss a system dialog via simctl privacy grant + button click fallback."""
    # Step 1: Detect system dialog
    detect_resp = await resolve_and_send(simulator, CMD_DIALOG, {"action": "detect_system"})

    if detect_resp.get("status") == "error":
        return detect_resp

    data = detect_resp.get("data", detect_resp)
    if not data.get("detected"):
        return {"status": "ok", "dismissed": False, "reason": "No system dialog detected"}

    # Step 2: Resolve simulator + bundle ID for simctl
    if not resolve_simulator:
        return {"status": "error", "error": "resolve_simulator not available"}
    try:
        sim = resolve_simulator(simulator)
    except RuntimeError as e:
        return {"status": "error", "error": str(e)}

    bid = get_config().get("bundle_id")
    if not bid:
        return {"status": "error", "error": "No bundle_id configured (set APP_BUNDLE_ID in .env)"}

    # Step 3: Infer permissions from intercepted dialog text (if available)
    permissions_to_try = []
    if data.get("intercepted_dialog_count", 0) > 0:
        current_resp = await resolve_and_send(simulator, CMD_DIALOG, {"action": "current"})
        cd = current_resp.get("data", current_resp)
        title = cd.get("title", "")
        message = cd.get("message", "")
        permissions_to_try = _infer_permissions(f"{title} {message}")

    # Fall back to all common permissions if we couldn't infer
    if not permissions_to_try:
        permissions_to_try = list(_ALL_PERMISSIONS)

    # Step 4: Grant permissions via simctl
    granted = []
    for perm in permissions_to_try:
        result = subprocess.run(
            ["xcrun", "simctl", "privacy", sim, "grant", perm, bid],
            capture_output=True,
            text=True,
        )
        if result.returncode == 0:
            granted.append(perm)

    # Brief wait for dialog to clear
    await asyncio.sleep(0.5)

    # Step 5: Re-detect
    recheck_resp = await resolve_and_send(simulator, CMD_DIALOG, {"action": "detect_system"})
    recheck_data = recheck_resp.get("data", recheck_resp)
    recheck_detected = recheck_data.get("detected", True)

    if not recheck_detected:
        return {
            "status": "ok",
            "dismissed": True,
            "method": "privacy_grant",
            "permissions_granted": granted,
        }

    # Step 6: Fall back to macOS Accessibility API (AXUIElement) — clicks buttons
    # directly in the Simulator window, works for SpringBoard-rendered dialogs
    # that the in-process interceptor can't reach.
    ax_result = await asyncio.get_event_loop().run_in_executor(None, _ax_dismiss)
    if ax_result.get("dismissed"):
        return {
            "status": "ok",
            "dismissed": True,
            "method": "ax_accessibility",
            "button": ax_result.get("button"),
            "permissions_granted": granted,
        }

    # Step 7: Last resort — try in-process button click (works for intercepted alerts)
    for btn in _PERMISSION_BUTTONS:
        dismiss_resp = await resolve_and_send(simulator, CMD_DIALOG, {"action": "dismiss", "button": btn})
        dd = dismiss_resp.get("data", dismiss_resp)
        if dd.get("dismissed"):
            return {
                "status": "ok",
                "dismissed": True,
                "method": "button_click",
                "button": btn,
                "permissions_granted": granted,
            }

    # Could not dismiss
    return {
        "status": "ok",
        "dismissed": False,
        "reason": "System dialog detected but could not dismiss",
        "permissions_granted": granted,
        "suggestion": "Try tapping the dialog button manually or use 'simulator permissions' tool",
    }


def register_dialog_tools(mcp, resolve_and_send, resolve_simulator=None):
    """Register dialog tool on the given MCP server.

    Args:
        mcp: FastMCP server instance.
        resolve_and_send: async (simulator, cmd, params?, timeout?) -> dict
        resolve_simulator: (udid_or_none) -> str — resolve simulator UDID.
    """

    @mcp.tool()
    async def dialog(
        simulator: str | None = Field(default=None, description="Simulator UDID"),
        action: str = Field(
            description="Action: list, current, dismiss, dismiss_system, detect_system, auto_dismiss, share_sheet, dismiss_sheet"
        ),
        button: str | None = Field(default=None, description="Button title to tap (for dismiss action)"),
        enabled: bool | None = Field(default=None, description="Enable/disable auto-dismiss (for auto_dismiss action)"),
        buttons: str | None = Field(
            default=None, description='JSON array of button titles for auto-dismiss (e.g. \'["Allow","OK"]\')'
        ),
    ) -> str:
        """Interact with system dialogs (alerts, permission prompts, share sheets).
        - list: see all pending dialogs
        - current: get the topmost dialog
        - dismiss: tap a button on the current dialog
        - dismiss_system: detect + dismiss system dialog in one step (tries simctl privacy grant, then button click fallback)
        - detect_system: single source of truth for ALL dialogs — combines in-process (intercepted UIAlertControllers) + system (SpringBoard via macOS Accessibility). Returns both signals.
        - auto_dismiss: auto-handle permission dialogs (Allow, OK, etc.)
        - share_sheet: check if a share sheet is showing
        - dismiss_sheet: close the share sheet"""
        if action == "dismiss_system":
            result = await _dismiss_system_dialog(simulator, resolve_and_send, resolve_simulator)
            return json.dumps(result, indent=2) if isinstance(result, dict) else result

        if action == "detect_system":
            # Single source of truth: combine in-process (dylib) + AX (macOS) detection.
            # In-process catches UIAlertControllers intercepted by present() swizzle.
            # AX catches SpringBoard dialogs (permissions, tracking) rendered outside the app.
            in_process_resp = await resolve_and_send(simulator, CMD_DIALOG, {"action": "detect_system"})
            ip_data = in_process_resp.get("data", in_process_resp)

            ax_result = {"detected": False, "buttons": [], "pids": []}
            try:
                ax_result = await asyncio.get_event_loop().run_in_executor(None, _ax_detect)
            except Exception:
                pass

            detected = ip_data.get("detected", False) or ax_result.get("detected", False)
            return json.dumps({
                "status": "ok",
                "detected": detected,
                "in_process": {
                    "detected": ip_data.get("detected", False),
                    "confidence": ip_data.get("confidence", "none"),
                    "intercepted_dialogs": ip_data.get("intercepted_dialog_count", 0),
                    "signals": ip_data.get("signals", []),
                },
                "system": {
                    "detected": ax_result.get("detected", False),
                    "buttons": ax_result.get("buttons", []),
                },
            }, indent=2)

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
        resp = await resolve_and_send(simulator, CMD_DIALOG, params)
        return json.dumps(resp, indent=2) if isinstance(resp, dict) else resp

"""Dialog tool definition for Pepper MCP.

Tool definitions for: dialog.
Includes system-dialog dismiss helper that prefers AX button taps and falls
back to simctl privacy grant only when taps fail (TCC writes SIGKILL the app).
"""

from __future__ import annotations

import asyncio
import functools
import subprocess

from pydantic import Field

from .pepper_ax import detect_dialog as _ax_detect
from .pepper_ax import find_and_dismiss_dialog as _ax_dismiss
from .pepper_commands import CMD_DIALOG
from .pepper_common import get_config, json_dumps, require_parse_json

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

# Common system dialog buttons in preference order
_SYSTEM_BUTTONS = [
    "Allow While Using App",
    "Allow Once",
    "Allow",
    "Open",  # deep link / universal link confirmation
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


async def _dismiss_system_dialog(simulator, resolve_and_send, resolve_simulator, button=None):
    """Detect and dismiss a system dialog.

    Try real button taps first (AX, then in-process), and fall back to
    `simctl privacy grant` only as a last resort. TCC writes on a running app
    cause iOS to SIGKILL the process, which takes the injected dylib with it,
    so the caller has to redeploy. AX taps click the real button in the
    Simulator window and leave the app alive.

    Args:
        button: Optional exact button title to tap. When provided, AX taps
            only that button and skips the "tap any allow-like button" default.
            Use this to choose between multi-option prompts (e.g. pick
            "Limit Access" vs "Allow Access to All Photos").
    """
    # Step 1: Detect system dialog — combine in-process (dylib) + AX (macOS) detection.
    detect_resp = await resolve_and_send(simulator, CMD_DIALOG, {"action": "detect_system"})

    if detect_resp.get("status") == "error":
        return detect_resp

    data = detect_resp.get("data", detect_resp)
    dylib_detected = data.get("detected", False)

    ax_detect_result = {"detected": False, "buttons": [], "pids": []}
    if not dylib_detected:
        try:
            ax_detect_result = await asyncio.get_running_loop().run_in_executor(None, _ax_detect)
        except Exception:
            pass

    if not dylib_detected and not ax_detect_result.get("detected", False):
        return {"status": "ok", "dismissed": False, "reason": "No system dialog detected"}

    # Step 2: AX click — real tap on the Simulator window, no TCC write, app stays alive.
    # Handles SpringBoard-rendered dialogs (permissions, tracking, deep links).
    try:
        ax_result = await asyncio.get_running_loop().run_in_executor(
            None, functools.partial(_ax_dismiss, target_title=button)
        )
    except Exception as e:
        ax_result = {"dismissed": False, "error": str(e), "buttons": []}
    if ax_result.get("dismissed"):
        return {
            "status": "ok",
            "dismissed": True,
            "method": "ax_accessibility",
            "button": ax_result.get("button"),
            "buttons": ax_result.get("buttons", []),
        }
    # Surface the button list we saw even if we didn't tap — callers can use
    # it to pick a specific title and retry with button=.
    ax_buttons = ax_result.get("buttons", [])

    # Step 3: In-process button click — handles UIAlertControllers caught by the
    # present() swizzle (AX can't see these; they don't reach the window tree).
    for btn in _SYSTEM_BUTTONS:
        dismiss_resp = await resolve_and_send(simulator, CMD_DIALOG, {"action": "dismiss", "button": btn})
        dd = dismiss_resp.get("data", dismiss_resp)
        if dd.get("dismissed"):
            return {
                "status": "ok",
                "dismissed": True,
                "method": "button_click",
                "button": btn,
                "buttons": ax_buttons,
            }

    # Step 4: Last resort — simctl privacy grant. TCC mutations invalidate the
    # running process's entitlements and iOS SIGKILLs it. Only reach here when
    # the tap paths above couldn't dismiss, and warn the caller in the response.
    if not resolve_simulator:
        return {"status": "error", "error": "resolve_simulator not available"}
    try:
        sim = resolve_simulator(simulator)
    except RuntimeError as e:
        return {"status": "error", "error": str(e)}

    bid = get_config().get("bundle_id")
    if not bid:
        return {"status": "error", "error": "No bundle_id configured (set APP_BUNDLE_ID in .env)"}

    permissions_to_try: list[str] = []
    if data.get("intercepted_dialog_count", 0) > 0:
        current_resp = await resolve_and_send(simulator, CMD_DIALOG, {"action": "current"})
        cd = current_resp.get("data", current_resp)
        title = cd.get("title", "")
        message = cd.get("message", "")
        permissions_to_try = _infer_permissions(f"{title} {message}")
    if not permissions_to_try:
        permissions_to_try = list(_ALL_PERMISSIONS)

    granted = []
    for perm in permissions_to_try:
        result = subprocess.run(
            ["xcrun", "simctl", "privacy", sim, "grant", perm, bid],
            capture_output=True,
            text=True,
        )
        if result.returncode == 0:
            granted.append(perm)

    await asyncio.sleep(0.5)

    recheck_resp = await resolve_and_send(simulator, CMD_DIALOG, {"action": "detect_system"})
    recheck_data = recheck_resp.get("data", recheck_resp)
    recheck_detected = recheck_data.get("detected", False)
    if not recheck_detected:
        try:
            ax_recheck = await asyncio.get_running_loop().run_in_executor(None, _ax_detect)
            recheck_detected = ax_recheck.get("detected", False)
        except Exception:
            pass

    if not recheck_detected:
        return {
            "status": "ok",
            "dismissed": True,
            "method": "privacy_grant",
            "permissions_granted": granted,
            "buttons": ax_buttons,
            "warning": (
                "simctl privacy grant writes to TCC and SIGKILLs the target app. "
                "The Pepper dylib died with it — redeploy via app_build before further Pepper calls."
            ),
        }

    return {
        "status": "ok",
        "dismissed": False,
        "reason": "System dialog detected but could not dismiss",
        "permissions_granted": granted,
        "buttons": ax_buttons,
        "suggestion": (
            "Retry nav_dialog dismiss_system with button='<exact title>' from the "
            "'buttons' list above. Or tap manually in the Simulator."
        ),
    }


def register_dialog_tools(mcp, resolve_and_send, resolve_simulator=None):
    """Register dialog tool on the given MCP server.

    Args:
        mcp: FastMCP server instance.
        resolve_and_send: async (simulator, cmd, params?, timeout?) -> dict
        resolve_simulator: (udid_or_none) -> str — resolve simulator UDID.
    """

    @mcp.tool(name="nav_dialog")
    async def dialog(
        simulator: str | None = Field(default=None, description="Simulator UDID"),
        action: str = Field(
            description="Action: list, current, dismiss, dismiss_system, detect_system, auto_dismiss, share_sheet, dismiss_sheet"
        ),
        button: str | None = Field(
            default=None,
            description=(
                "Button title to tap. For action='dismiss', the title of an "
                "in-app UIAlertController button. For action='dismiss_system', "
                "the exact title of a system-dialog button (see 'buttons' in a "
                "previous dismiss_system response to pick from multi-option "
                "prompts like 'Limit Access' vs 'Allow Access to All Photos')."
            ),
        ),
        enabled: bool | None = Field(default=None, description="Enable/disable auto-dismiss (for auto_dismiss action)"),
        buttons: str | None = Field(
            default=None, description='JSON array of button titles for auto-dismiss (e.g. \'["Allow","OK"]\')'
        ),
    ) -> str:
        """Interact with dialogs. For system permission prompts (notifications, location, photos, etc.) ALWAYS use action='dismiss_system' — these are SpringBoard dialogs that 'dismiss' and 'tap' cannot reach. 'dismiss' with button= only works for in-app UIAlertControllers."""
        if action == "dismiss_system":
            result = await _dismiss_system_dialog(
                simulator, resolve_and_send, resolve_simulator, button=button
            )
            return json_dumps(result) if isinstance(result, dict) else result

        if action == "detect_system":
            # Single source of truth: combine in-process (dylib) + AX (macOS) detection.
            # In-process catches UIAlertControllers intercepted by present() swizzle.
            # AX catches SpringBoard dialogs (permissions, tracking) rendered outside the app.
            in_process_resp = await resolve_and_send(simulator, CMD_DIALOG, {"action": "detect_system"})
            ip_data = in_process_resp.get("data", in_process_resp)

            ax_result = {"detected": False, "buttons": [], "pids": []}
            try:
                ax_result = await asyncio.get_running_loop().run_in_executor(None, _ax_detect)
            except Exception:
                pass

            detected = ip_data.get("detected", False) or ax_result.get("detected", False)
            return json_dumps(
                {
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
                }
            )

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
        return json_dumps(resp) if isinstance(resp, dict) else resp

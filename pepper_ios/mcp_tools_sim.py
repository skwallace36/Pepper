"""Simulator and raw command tool definitions for Pepper MCP.

Tool definitions for: raw (send any command), simulator (simctl operations).
"""

from __future__ import annotations

import os
import subprocess

from pydantic import Field

from . import pepper_sessions
from .pepper_common import get_config, list_simulators, require_parse_json


def register_sim_tools(mcp, resolve_and_send, resolve_simulator):
    """Register simulator and raw command tools on the given MCP server.

    Args:
        mcp: FastMCP server instance.
        resolve_and_send: async (simulator, cmd, params?, timeout?) -> dict
        resolve_simulator: (udid_or_none) -> str — resolve simulator UDID.
    """

    @mcp.tool(name="sim_raw")
    async def raw(
        simulator: str | None = Field(default=None, description="Simulator UDID"),
        cmd: str = Field(description="Command name"),
        params: str | dict | None = Field(default=None, description="JSON params (string or object)"),
        timeout: float = Field(default=10, description="Timeout in seconds"),
    ) -> str:
        """Send a raw command to the Pepper dylib. Escape hatch for commands not exposed as dedicated tools.

        IMPORTANT: This is NOT a code evaluation tool. You cannot execute arbitrary Swift/ObjC at runtime.
        Only registered dylib commands work. Send cmd="help" to list valid commands.

        Most commands already have dedicated MCP tools — prefer those. Use raw only for:
        - Commands without a dedicated tool (e.g. batch, deeplinks, identify_selected, identify_icons, memory, scroll_to, watch, unwatch)
        - Passing unusual params not exposed by a dedicated tool's schema
        """
        p = None
        if params:
            if isinstance(params, dict):
                p = params
            else:
                try:
                    p = require_parse_json(params, "params")
                except ValueError as e:
                    return f"Error: {e}"
        return await resolve_and_send(simulator, cmd, p, timeout)

    @mcp.tool()
    async def sim_control(
        action: str = Field(
            description="Action: list | install | uninstall | location | permissions | privacy_reset | biometric | open_url | addmedia | boot | shutdown | erase | status_bar"
        ),
        simulator_id: str | None = Field(default=None, description="Simulator UDID (auto-resolved if only one booted)"),
        app_path: str | None = Field(default=None, description="Path to .app/.ipa for action=install"),
        bundle_id: str | None = Field(default=None, description="App bundle ID for action=uninstall"),
        latitude: float | None = Field(default=None, description="Latitude for action=location"),
        longitude: float | None = Field(default=None, description="Longitude for action=location"),
        permission: str | None = Field(
            default=None,
            description="Permission name (for action=permissions). See pepper://reference/actions for values.",
        ),
        permission_value: str | None = Field(default=None, description="Permission value: grant, revoke, reset"),
        biometric_action: str | None = Field(default=None, description="For action=biometric: enroll | match | nonmatch"),
        biometric_type: str | None = Field(default=None, description="For action=biometric: face (Face ID) or finger (Touch ID). Default: face"),
        url: str | None = Field(default=None, description="URL for action=open_url (deep link or web)"),
        media_path: str | None = Field(default=None, description="Path to image/video file for action=addmedia"),
        clear_time: bool = Field(default=False, description="For action=status_bar: clear override instead of setting"),
        time: str | None = Field(default=None, description="For action=status_bar: time string like '09:41'"),
    ) -> str:
        """Control the iOS Simulator environment via simctl — permissions, GPS, biometrics, installed apps, and device lifecycle."""

        sim = simulator_id
        if action == "list":
            sims = list_simulators()
            sessions = {s["udid"]: s for s in pepper_sessions.list_sessions()}
            if not sims:
                # Still show session info even if no Pepper running
                if sessions:
                    lines = []
                    for udid, sess in sessions.items():
                        status = "live" if sess.get("live") else "stale"
                        label = f" ({sess['label']})" if sess.get("label") else ""
                        lines.append(f"  {udid} — session PID {sess['pid']}{label} [{status}]")
                    return f"No Pepper instances running. {len(sessions)} session(s):\n" + "\n".join(lines)
                return "No Pepper instances running."
            lines = []
            for s in sims:
                sess = sessions.get(s["udid"])
                if sess and sess.get("live"):
                    owner = f" [PID {sess['pid']}"
                    if sess.get("label"):
                        owner += f" ({sess['label']})"
                    if sess.get("pid") == os.getpid():
                        owner += ", this session"
                    owner += "]"
                else:
                    owner = " [unclaimed]"
                lines.append(f"  {s['udid']} → port {s['port']}{owner}")
            return f"{len(sims)} simulator(s):\n" + "\n".join(lines)

        # All other actions need a simulator
        if not sim:
            try:
                sim = resolve_simulator(None)
            except RuntimeError as e:
                return str(e)

        if action == "install":
            if not app_path:
                return "Error: app_path required for install"
            result = subprocess.run(["xcrun", "simctl", "install", sim, app_path], capture_output=True, text=True)
            return f"Installed {app_path}" if result.returncode == 0 else f"Install failed: {result.stderr.strip()}"

        elif action == "uninstall":
            bid = bundle_id or get_config().get("bundle_id")
            if not bid:
                return "Error: bundle_id required for uninstall"
            result = subprocess.run(["xcrun", "simctl", "uninstall", sim, bid], capture_output=True, text=True)
            return f"Uninstalled {bid}" if result.returncode == 0 else f"Uninstall failed: {result.stderr.strip()}"

        elif action == "location":
            if latitude is not None and longitude is not None:
                if latitude == 0 and longitude == 0:
                    result = subprocess.run(
                        ["xcrun", "simctl", "location", sim, "clear"], capture_output=True, text=True
                    )
                    return "Location cleared" if result.returncode == 0 else f"Failed: {result.stderr.strip()}"
                result = subprocess.run(
                    ["xcrun", "simctl", "location", sim, "set", f"{latitude},{longitude}"],
                    capture_output=True,
                    text=True,
                )
                return (
                    f"Location set to {latitude}, {longitude}"
                    if result.returncode == 0
                    else f"Failed: {result.stderr.strip()}"
                )
            return "Error: latitude and longitude required for location"

        elif action == "permissions":
            bid = bundle_id or get_config().get("bundle_id")
            if not bid or not permission or not permission_value:
                return "Error: bundle_id, permission, and permission_value required"
            if permission_value not in ("grant", "revoke", "reset"):
                return "Error: permission_value must be grant, revoke, or reset"
            result = subprocess.run(
                ["xcrun", "simctl", "privacy", sim, permission_value, permission, bid], capture_output=True, text=True
            )
            return (
                f"Permission {permission} {permission_value}ed for {bid}"
                if result.returncode == 0
                else f"Failed: {result.stderr.strip()}"
            )

        elif action == "privacy_reset":
            bid = bundle_id or get_config().get("bundle_id")
            if not bid:
                return "Error: bundle_id required for privacy_reset"
            result = subprocess.run(
                ["xcrun", "simctl", "privacy", sim, "reset", "all", bid], capture_output=True, text=True
            )
            return (
                f"All privacy permissions reset for {bid}"
                if result.returncode == 0
                else f"Failed: {result.stderr.strip()}"
            )

        elif action in ("biometric", "biometrics"):
            bio_action = biometric_action or "enroll"
            bio_type = biometric_type or "face"
            if bio_type not in ("face", "finger"):
                return "Error: biometric_type must be 'face' or 'finger'"
            if bio_action not in ("enroll", "match", "nonmatch"):
                return f"Unknown biometric_action '{bio_action}'. Use: enroll, match, nonmatch"
            flag = "--face" if bio_type == "face" else "--finger"
            label = "Face ID" if bio_type == "face" else "Touch ID"
            result = subprocess.run(
                ["xcrun", "simctl", "ui", sim, "biometric", bio_action, flag],
                capture_output=True,
                text=True,
            )
            if result.returncode != 0:
                return f"Failed: {result.stderr.strip()}"
            msgs = {"enroll": f"{label} enrolled", "match": f"{label} match sent", "nonmatch": f"{label} non-match sent"}
            return msgs[bio_action]

        elif action == "open_url":
            if not url:
                return "Error: url required for open_url"
            result = subprocess.run(["xcrun", "simctl", "openurl", sim, url], capture_output=True, text=True)
            return f"Opened {url}" if result.returncode == 0 else f"Failed: {result.stderr.strip()}"

        elif action == "addmedia":
            if not media_path:
                return "Error: media_path required for addmedia (path to image or video file)"
            if not os.path.exists(media_path):
                return f"Error: file not found: {media_path}"
            result = subprocess.run(["xcrun", "simctl", "addmedia", sim, media_path], capture_output=True, text=True)
            return (
                f"Added {os.path.basename(media_path)} to camera roll"
                if result.returncode == 0
                else f"Failed: {result.stderr.strip()}"
            )

        elif action == "boot":
            result = subprocess.run(["xcrun", "simctl", "boot", sim], capture_output=True, text=True)
            return f"Booted {sim}" if result.returncode == 0 else f"Failed: {result.stderr.strip()}"

        elif action == "shutdown":
            result = subprocess.run(["xcrun", "simctl", "shutdown", sim], capture_output=True, text=True)
            return f"Shut down {sim}" if result.returncode == 0 else f"Failed: {result.stderr.strip()}"

        elif action == "erase":
            result = subprocess.run(["xcrun", "simctl", "erase", sim], capture_output=True, text=True)
            return f"Erased {sim}" if result.returncode == 0 else f"Failed: {result.stderr.strip()}"

        elif action == "status_bar":
            if clear_time:
                result = subprocess.run(["xcrun", "simctl", "status_bar", sim, "clear"], capture_output=True, text=True)
                return "Status bar cleared" if result.returncode == 0 else f"Failed: {result.stderr.strip()}"
            cmd = ["xcrun", "simctl", "status_bar", sim, "override"]
            if time:
                cmd.extend(["--time", time])
            result = subprocess.run(cmd, capture_output=True, text=True)
            return "Status bar overridden" if result.returncode == 0 else f"Failed: {result.stderr.strip()}"

        return f"Unknown action '{action}'. Use: list, install, uninstall, location, permissions, privacy_reset, biometric, open_url, addmedia, boot, shutdown, erase, status_bar"

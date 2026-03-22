"""Simulator and raw command tool definitions for Pepper MCP.

Tool definitions for: raw (send any command), simulator (simctl operations).
"""

import json
import os
import subprocess
from typing import Optional

from pydantic import Field

import pepper_sessions
from pepper_common import get_config, list_simulators


def require_parse_json(value, field_name="value"):
    """Parse a string as JSON, raising ValueError with a descriptive message on failure."""
    try:
        return json.loads(value)
    except json.JSONDecodeError as e:
        raise ValueError(f"{field_name} must be valid JSON: {e}")


def register_sim_tools(mcp, resolve_and_send, resolve_simulator):
    """Register simulator and raw command tools on the given MCP server.

    Args:
        mcp: FastMCP server instance.
        resolve_and_send: async (simulator, cmd, params?, timeout?) -> str
        resolve_simulator: (udid_or_none) -> str — resolve simulator UDID.
    """

    @mcp.tool()
    async def raw(
        simulator: Optional[str] = Field(default=None, description="Simulator UDID"),
        cmd: str = Field(description="Command name"),
        params: Optional[str] = Field(default=None, description="JSON params string"),
        timeout: float = Field(default=10, description="Timeout in seconds"),
    ) -> str:
        """Send any raw command to Pepper. Use for commands not covered by other tools."""
        p = None
        if params:
            try:
                p = require_parse_json(params, "params")
            except ValueError as e:
                return f"Error: {e}"
        return await resolve_and_send(simulator, cmd, p, timeout)

    @mcp.tool()
    async def simulator(
        action: str = Field(description="Action: list, install, uninstall, location, permissions, biometrics, privacy_reset, open_url, addmedia, boot, shutdown, erase, status_bar"),
        simulator_id: Optional[str] = Field(default=None, description="Simulator UDID (auto-resolved if only one booted)"),
        app_path: Optional[str] = Field(default=None, description="Path to .app/.ipa for action=install"),
        bundle_id: Optional[str] = Field(default=None, description="App bundle ID for action=uninstall"),
        latitude: Optional[float] = Field(default=None, description="Latitude for action=location"),
        longitude: Optional[float] = Field(default=None, description="Longitude for action=location"),
        permission: Optional[str] = Field(default=None, description="Permission for action=permissions: photos, camera, microphone, contacts, calendar, reminders, location-always, location-when-in-use, notifications, health"),
        permission_value: Optional[str] = Field(default=None, description="Permission value: grant, revoke, reset"),
        biometric_type: Optional[str] = Field(default=None, description="For action=biometrics: enroll or match"),
        url: Optional[str] = Field(default=None, description="URL for action=open_url (deep link or web)"),
        media_path: Optional[str] = Field(default=None, description="Path to image/video file for action=addmedia"),
        clear_time: bool = Field(default=False, description="For action=status_bar: clear override instead of setting"),
        time: Optional[str] = Field(default=None, description="For action=status_bar: time string like '09:41'"),
    ) -> str:
        """Control the simulator itself (not the app process) — permissions, GPS, biometrics, and more.

        Actions:
          list — list simulators with active Pepper connections
          install — install an app from .app/.ipa path
          uninstall — remove an app by bundle ID
          location — set simulated GPS coordinates (latitude + longitude). Clear with latitude=0, longitude=0.
            Use this to test location-dependent features without physical movement.
          permissions — grant/revoke/reset app permissions (requires bundle_id + permission + permission_value).
            Permissions: photos, camera, microphone, contacts, calendar, reminders,
            location-always, location-when-in-use, notifications, health.
          biometrics — enroll Face ID (biometric_type='enroll') or trigger match/fail (biometric_type='match').
            Use to test auth flows that require Face ID.
          privacy_reset — reset ALL privacy permissions for a bundle ID (starts fresh)
          open_url — open a URL (deep link or web) in the simulator. Use for testing deep link routing.
          addmedia — inject a photo or video into the simulator's camera roll (requires media_path).
            Use to test photo pickers, profile image uploads, gallery features, etc.
          boot — boot the simulator (prefer this over raw simctl boot)
          shutdown — shutdown the simulator
          erase — factory reset the simulator (WARNING: destroys all data and apps)
          status_bar — override status bar display (set time='09:41' for screenshots, clear_time=true to reset)

        Related tools: deploy (restart app with Pepper), flags (feature flag overrides),
        defaults (set app UserDefaults from outside)."""

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
            result = subprocess.run(
                ["xcrun", "simctl", "install", sim, app_path],
                capture_output=True, text=True
            )
            return f"Installed {app_path}" if result.returncode == 0 else f"Install failed: {result.stderr.strip()}"

        elif action == "uninstall":
            bid = bundle_id or get_config().get("bundle_id")
            if not bid:
                return "Error: bundle_id required for uninstall"
            result = subprocess.run(
                ["xcrun", "simctl", "uninstall", sim, bid],
                capture_output=True, text=True
            )
            return f"Uninstalled {bid}" if result.returncode == 0 else f"Uninstall failed: {result.stderr.strip()}"

        elif action == "location":
            if latitude is not None and longitude is not None:
                if latitude == 0 and longitude == 0:
                    result = subprocess.run(
                        ["xcrun", "simctl", "location", sim, "clear"],
                        capture_output=True, text=True
                    )
                    return "Location cleared" if result.returncode == 0 else f"Failed: {result.stderr.strip()}"
                result = subprocess.run(
                    ["xcrun", "simctl", "location", sim, "set", f"{latitude},{longitude}"],
                    capture_output=True, text=True
                )
                return f"Location set to {latitude}, {longitude}" if result.returncode == 0 else f"Failed: {result.stderr.strip()}"
            return "Error: latitude and longitude required for location"

        elif action == "permissions":
            bid = bundle_id or get_config().get("bundle_id")
            if not bid or not permission or not permission_value:
                return "Error: bundle_id, permission, and permission_value required"
            if permission_value not in ("grant", "revoke", "reset"):
                return "Error: permission_value must be grant, revoke, or reset"
            result = subprocess.run(
                ["xcrun", "simctl", "privacy", sim, permission_value, permission, bid],
                capture_output=True, text=True
            )
            return f"Permission {permission} {permission_value}ed for {bid}" if result.returncode == 0 else f"Failed: {result.stderr.strip()}"

        elif action == "privacy_reset":
            bid = bundle_id or get_config().get("bundle_id")
            if not bid:
                return "Error: bundle_id required for privacy_reset"
            result = subprocess.run(
                ["xcrun", "simctl", "privacy", sim, "reset", "all", bid],
                capture_output=True, text=True
            )
            return f"All privacy permissions reset for {bid}" if result.returncode == 0 else f"Failed: {result.stderr.strip()}"

        elif action == "biometrics":
            if biometric_type == "enroll":
                result = subprocess.run(
                    ["xcrun", "simctl", "spawn", sim, "notifyutil", "-s", "com.apple.BiometricKit.enrollmentChanged", "1"],
                    capture_output=True, text=True
                )
                subprocess.run(
                    ["xcrun", "simctl", "spawn", sim, "notifyutil", "-p", "com.apple.BiometricKit.enrollmentChanged"],
                    capture_output=True, text=True
                )
                return "Face ID enrolled" if result.returncode == 0 else f"Failed: {result.stderr.strip()}"
            elif biometric_type == "match":
                result = subprocess.run(
                    ["xcrun", "simctl", "spawn", sim, "notifyutil", "-p", "com.apple.BiometricKit_Sim.fingerTouch.match"],
                    capture_output=True, text=True
                )
                return "Biometric match sent" if result.returncode == 0 else f"Failed: {result.stderr.strip()}"
            return "Error: biometric_type must be 'enroll' or 'match'"

        elif action == "open_url":
            if not url:
                return "Error: url required for open_url"
            result = subprocess.run(
                ["xcrun", "simctl", "openurl", sim, url],
                capture_output=True, text=True
            )
            return f"Opened {url}" if result.returncode == 0 else f"Failed: {result.stderr.strip()}"

        elif action == "addmedia":
            if not media_path:
                return "Error: media_path required for addmedia (path to image or video file)"
            if not os.path.exists(media_path):
                return f"Error: file not found: {media_path}"
            result = subprocess.run(
                ["xcrun", "simctl", "addmedia", sim, media_path],
                capture_output=True, text=True
            )
            return f"Added {os.path.basename(media_path)} to camera roll" if result.returncode == 0 else f"Failed: {result.stderr.strip()}"

        elif action == "boot":
            result = subprocess.run(
                ["xcrun", "simctl", "boot", sim],
                capture_output=True, text=True
            )
            return f"Booted {sim}" if result.returncode == 0 else f"Failed: {result.stderr.strip()}"

        elif action == "shutdown":
            result = subprocess.run(
                ["xcrun", "simctl", "shutdown", sim],
                capture_output=True, text=True
            )
            return f"Shut down {sim}" if result.returncode == 0 else f"Failed: {result.stderr.strip()}"

        elif action == "erase":
            result = subprocess.run(
                ["xcrun", "simctl", "erase", sim],
                capture_output=True, text=True
            )
            return f"Erased {sim}" if result.returncode == 0 else f"Failed: {result.stderr.strip()}"

        elif action == "status_bar":
            if clear_time:
                result = subprocess.run(
                    ["xcrun", "simctl", "status_bar", sim, "clear"],
                    capture_output=True, text=True
                )
                return "Status bar cleared" if result.returncode == 0 else f"Failed: {result.stderr.strip()}"
            cmd = ["xcrun", "simctl", "status_bar", sim, "override"]
            if time:
                cmd.extend(["--time", time])
            result = subprocess.run(cmd, capture_output=True, text=True)
            return "Status bar overridden" if result.returncode == 0 else f"Failed: {result.stderr.strip()}"

        return f"Unknown action '{action}'. Use: list, install, uninstall, location, permissions, biometrics, privacy_reset, open_url, addmedia, boot, shutdown, erase, status_bar"

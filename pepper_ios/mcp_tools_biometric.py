"""Biometric simulation tool for Pepper MCP.

Tool definition for: biometric (Face ID / Touch ID simulation via simctl).
"""

from __future__ import annotations

import subprocess

from pydantic import Field


def register_biometric_tools(mcp, resolve_simulator):
    """Register biometric simulation tools on the given MCP server.

    Args:
        mcp: FastMCP server instance.
        resolve_simulator: (udid_or_none) -> str — resolve simulator UDID.
    """

    @mcp.tool()
    async def biometric(
        action: str = Field(description="Action: enroll | match | nonmatch"),
        biometric_type: str = Field(
            default="face",
            description="Biometric type: face (Face ID) or finger (Touch ID)",
        ),
        simulator: str | None = Field(default=None, description="Simulator UDID (auto-resolved if only one booted)"),
    ) -> str:
        """Simulate Face ID / Touch ID on the iOS Simulator.

        Wraps `xcrun simctl ui biometric` to enroll, match, or fail biometric authentication.

        Actions:
        - enroll: enroll the biometric (required before match/nonmatch will work)
        - match: simulate a successful biometric authentication
        - nonmatch: simulate a failed biometric authentication attempt

        Types:
        - face: Face ID (default)
        - finger: Touch ID
        """
        if biometric_type not in ("face", "finger"):
            return "Error: biometric_type must be 'face' or 'finger'"

        flag = "--face" if biometric_type == "face" else "--finger"
        label = "Face ID" if biometric_type == "face" else "Touch ID"

        try:
            sim = resolve_simulator(simulator)
        except RuntimeError as e:
            return str(e)

        if action == "enroll":
            result = subprocess.run(
                ["xcrun", "simctl", "ui", sim, "biometric", "enroll", flag],
                capture_output=True,
                text=True,
            )
            return f"{label} enrolled" if result.returncode == 0 else f"Failed: {result.stderr.strip()}"

        elif action == "match":
            result = subprocess.run(
                ["xcrun", "simctl", "ui", sim, "biometric", "match", flag],
                capture_output=True,
                text=True,
            )
            return f"{label} match sent" if result.returncode == 0 else f"Failed: {result.stderr.strip()}"

        elif action == "nonmatch":
            result = subprocess.run(
                ["xcrun", "simctl", "ui", sim, "biometric", "nonmatch", flag],
                capture_output=True,
                text=True,
            )
            return f"{label} non-match sent" if result.returncode == 0 else f"Failed: {result.stderr.strip()}"

        return f"Unknown action '{action}'. Use: enroll, match, nonmatch"

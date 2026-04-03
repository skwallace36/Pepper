"""GitHub issue filing tool for Pepper MCP.

Generates a pre-filled GitHub issue URL for the public Pepper repo.
The user clicks the link and reviews before submitting — nothing is
posted without explicit human action in the browser.

In dev mode (PEPPER_DEV=1 in .env or shell), the tool is registered
as an MCP tool for direct use. In public installs, the tool code is
present but not registered — users can see the implementation but
Claude won't call it autonomously.
"""

from __future__ import annotations

import json
import os
import platform
import subprocess
from urllib.parse import quote

from pydantic import Field

from . import __version__

REPO_URL = "https://github.com/skwallace36/Pepper"


def _run(cmd: list[str], timeout: int = 10) -> str:
    """Run a subprocess, return stdout or empty string on failure."""
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return r.stdout.strip()
    except Exception:
        return ""


def _gather_environment() -> str:
    """Collect environment info for the issue body."""
    lines = []
    lines.append(f"- **Pepper version:** {__version__}")
    lines.append(f"- **Python:** {platform.python_version()}")
    lines.append(f"- **macOS:** {platform.mac_ver()[0] or platform.platform()}")

    xcode = _run(["xcodebuild", "-version"])
    if xcode:
        lines.append(f"- **Xcode:** {xcode.splitlines()[0]}")

    booted = _run(["xcrun", "simctl", "list", "devices", "booted", "-j"])
    if booted:
        try:
            data = json.loads(booted)
            for runtime, devices in data.get("devices", {}).items():
                for d in devices:
                    if d.get("state") == "Booted":
                        rt = runtime.rsplit(".", 1)[-1].replace("-", " ")
                        lines.append(f"- **Simulator:** {d['name']} ({rt})")
                        break
        except Exception:
            pass

    return "\n".join(lines)


def is_dev_mode() -> bool:
    """Check if running in dev mode (private repo / local development)."""
    # Shell env is authoritative when set
    shell_val = os.environ.get("PEPPER_DEV", "").strip()
    if shell_val:
        return shell_val in ("1", "true")
    # Fall back to .env file
    try:
        from .pepper_common import load_env
        env = load_env()
        return env.get("PEPPER_DEV", "").strip() in ("1", "true")
    except Exception:
        return False


def register_issue_tools(mcp):
    """Register the report_issue tool — only in dev mode.

    In public installs, this is a no-op. The code is visible in the repo
    so users can see the feature exists, but the tool isn't exposed to Claude.
    """
    if not is_dev_mode():
        return

    @mcp.tool()
    async def report_issue(
        title: str = Field(description="Short issue title"),
        description: str = Field(description="What happened — steps to reproduce, expected vs actual behavior"),
        logs: str | None = Field(default=None, description="Relevant logs, crash reports, or error messages"),
        label: str = Field(default="bug", description="Issue label: bug, enhancement, question"),
    ) -> str:
        """Report a bug or request a feature on the Pepper GitHub repo. Returns a pre-filled URL to review and submit in your browser. Never include sensitive data (API keys, tokens, credentials) in any field."""
        valid_labels = {"bug", "enhancement", "question"}
        label_arg = label if label in valid_labels else "bug"

        body_parts = []
        body_parts.append("## Description\n")
        body_parts.append(description)

        if logs:
            body_parts.append("\n## Logs\n")
            body_parts.append(f"```\n{logs}\n```")
        else:
            body_parts.append("\n## Logs\n")
            body_parts.append("<!-- Paste any relevant logs, crash reports, or error messages here -->")

        body_parts.append("\n## Environment\n")
        body_parts.append(_gather_environment())

        body = "\n".join(body_parts)

        url = (
            f"{REPO_URL}/issues/new"
            f"?title={quote(title)}"
            f"&body={quote(body)}"
            f"&labels={quote(label_arg)}"
        )

        return f"Review and submit: {url}"

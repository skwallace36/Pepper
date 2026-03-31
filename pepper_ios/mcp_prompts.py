"""Register Pepper skills as MCP prompts so they're available in any connected repo."""

from __future__ import annotations

import os
from pathlib import Path

# ---------------------------------------------------------------------------
# Skill definitions: (prompt_name, description, skill_dir, has_screen_arg)
# ---------------------------------------------------------------------------
_SKILLS = [
    (
        "explore_app",
        "Systematically crawl a running iOS app to map screens, discover blind spots, and recommend adapter config",
        "explore-app",
        True,
    ),
    (
        "babysit",
        "Proactive health monitoring, drift detection, and issue management for the Pepper project",
        "babysit",
        False,
    ),
]


def _skills_dir() -> Path:
    """Return the .claude/skills/ directory relative to the repo root."""
    # mcp_server sets PEPPER_ROOT, fall back to relative path from this file
    root = os.environ.get("PEPPER_ROOT", str(Path(__file__).resolve().parent.parent))
    return Path(root) / ".claude" / "skills"


def _read_skill(dirname: str) -> str:
    """Read a SKILL.md file, stripping YAML frontmatter if present."""
    path = _skills_dir() / dirname / "SKILL.md"
    text = path.read_text()
    # Strip YAML frontmatter (--- ... ---)
    if text.startswith("---"):
        end = text.find("---", 3)
        if end != -1:
            text = text[end + 3:].lstrip("\n")
    return text


def register_prompts(mcp) -> None:
    """Register all skills as MCP prompts on the given FastMCP instance."""
    for prompt_name, description, skill_dir, has_screen_arg in _SKILLS:
        skill_content = _read_skill(skill_dir)
        _register_one(mcp, prompt_name, description, skill_content, has_screen_arg)


def _register_one(
    mcp, name: str, description: str, content: str, has_screen_arg: bool
) -> None:
    """Register a single skill as an MCP prompt."""
    if has_screen_arg:

        @mcp.prompt(name=name, description=description)
        def _prompt(screen: str = "") -> str:  # noqa: ARG001
            if screen:
                return f"{content}\n\n---\nTargeted mode: focus on the **{screen}** screen."
            return content

    else:

        @mcp.prompt(name=name, description=description)
        def _prompt() -> str:
            return content

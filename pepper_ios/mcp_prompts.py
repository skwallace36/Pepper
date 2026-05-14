"""Register Pepper skills as MCP prompts so they're available in any connected repo."""

from __future__ import annotations

import os
from importlib import resources
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


def _read_skill(dirname: str) -> str | None:
    """Read a SKILL.md file, stripping YAML frontmatter. Returns None if not found.

    Tries package data first (installed wheel), then falls back to the repo's
    .claude/skills/ directory (dev checkout).
    """
    text: str | None = None

    # Package data (bundled via pyproject.toml force-include)
    try:
        pkg_skill = resources.files("pepper_ios") / "skills" / dirname / "SKILL.md"
        if pkg_skill.is_file():
            text = pkg_skill.read_text(encoding="utf-8")
    except (FileNotFoundError, ModuleNotFoundError, AttributeError):
        pass

    # Dev-checkout fallback: <repo>/.claude/skills/<dirname>/SKILL.md
    if text is None:
        root = os.environ.get("PEPPER_ROOT", str(Path(__file__).resolve().parent.parent))
        path = Path(root) / ".claude" / "skills" / dirname / "SKILL.md"
        if path.is_file():
            text = path.read_text(encoding="utf-8")

    if text is None:
        return None

    # Strip YAML frontmatter (--- ... ---)
    if text.startswith("---"):
        end = text.find("---", 3)
        if end != -1:
            text = text[end + 3:].lstrip("\n")
    return text


def register_prompts(mcp) -> None:
    """Register all skills as MCP prompts on the given FastMCP instance.

    Skills with missing SKILL.md content are skipped — the server still starts.
    """
    for prompt_name, description, skill_dir, has_screen_arg in _SKILLS:
        skill_content = _read_skill(skill_dir)
        if skill_content is None:
            continue
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

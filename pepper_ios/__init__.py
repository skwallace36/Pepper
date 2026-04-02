"""pepper-ios — MCP server and CLI tools for Pepper iOS simulator control."""

from __future__ import annotations

import os
from pathlib import Path

__version__ = "0.2.0"


def _find_dylib() -> str:
    """Locate the Pepper dylib (framework binary).

    Resolution order:
    1. PEPPER_DYLIB_PATH env var (explicit override).
    2. Package data (pip-installed): pepper_ios/_dylib/Pepper.framework/Pepper.
    3. Development build dir: <repo>/build/Pepper.framework/Pepper.
    """
    # 1. Explicit env override
    env_path = os.environ.get("PEPPER_DYLIB_PATH", "")
    if env_path and os.path.isfile(env_path):
        return env_path

    # 2. Installed package data
    pkg_dylib = Path(__file__).parent / "_dylib" / "Pepper.framework" / "Pepper"
    if pkg_dylib.is_file():
        return str(pkg_dylib)

    # 3. Development build directory (repo root / build / ...)
    repo_root = Path(__file__).parent.parent
    dev_dylib = repo_root / "build" / "Pepper.framework" / "Pepper"
    if dev_dylib.is_file():
        return str(dev_dylib)

    # 4. Auto-download from GitHub Releases (pip installs)
    try:
        from .dylib_fetch import ensure_dylib
        return ensure_dylib()
    except Exception:
        pass

    return ""

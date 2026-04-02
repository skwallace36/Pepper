"""Download and cache prebuilt Pepper.framework from GitHub Releases."""

from __future__ import annotations

import os
import platform
import shutil
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.request import urlopen

GITHUB_REPO = "skwallace36/Pepper"
CACHE_DIR = Path.home() / ".pepper" / "frameworks"
FRAMEWORK_NAME = "Pepper.framework"


def _resolve_version() -> str:
    from . import __version__
    return __version__


def _asset_url(version: str) -> str:
    return f"https://github.com/{GITHUB_REPO}/releases/download/v{version}/{FRAMEWORK_NAME}.zip"


def _download(url: str, dest: Path) -> None:
    """Download url to dest atomically."""
    dest.parent.mkdir(parents=True, exist_ok=True)
    tmp_fd, tmp_path = tempfile.mkstemp(dir=dest.parent, suffix=".download")
    try:
        resp = urlopen(url, timeout=120)  # noqa: S310
        total = int(resp.headers.get("Content-Length", 0))
        downloaded = 0
        is_tty = hasattr(sys.stderr, "isatty") and sys.stderr.isatty()
        with os.fdopen(tmp_fd, "wb") as f:
            while True:
                chunk = resp.read(256 * 1024)
                if not chunk:
                    break
                f.write(chunk)
                downloaded += len(chunk)
                if is_tty and total:
                    pct = downloaded * 100 // total
                    print(f"\r  downloading Pepper.framework ... {pct}%", end="", file=sys.stderr)
        if is_tty and total:
            print(file=sys.stderr)
        shutil.move(tmp_path, dest)
    except BaseException:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        raise


def _codesign(framework_path: Path) -> None:
    """Ad-hoc codesign — zip extraction strips signatures."""
    subprocess.run(
        ["codesign", "--force", "--sign", "-", "--deep", str(framework_path)],
        capture_output=True,
    )


def ensure_dylib(version: str | None = None) -> str:
    """Return path to the Pepper dylib binary, downloading if needed.

    Caches to ~/.pepper/frameworks/<version>/Pepper.framework/Pepper.
    """
    ver = version or _resolve_version()
    framework_dir = CACHE_DIR / ver / FRAMEWORK_NAME
    binary = framework_dir / "Pepper"

    if binary.is_file():
        return str(binary)

    url = _asset_url(ver)
    zip_path = CACHE_DIR / ver / f"{FRAMEWORK_NAME}.zip"

    print(f"Pepper dylib not found locally — downloading v{ver} from GitHub Releases...", file=sys.stderr)
    try:
        _download(url, zip_path)
    except HTTPError as e:
        if e.code == 404:
            raise RuntimeError(
                f"No prebuilt dylib for v{ver} at {url}\n"
                f"Either upgrade pepper-ios or build from source: make build"
            ) from e
        raise RuntimeError(f"Download failed ({e.code}): {url}") from e
    except URLError as e:
        raise RuntimeError(
            f"Network error downloading dylib: {e.reason}\n"
            f"Build from source instead: make build"
        ) from e

    # Extract
    extract_dir = CACHE_DIR / ver
    with zipfile.ZipFile(zip_path) as zf:
        zf.extractall(extract_dir)
    zip_path.unlink(missing_ok=True)

    if not binary.is_file():
        raise RuntimeError(
            f"Zip extracted but {binary} not found. Archive may have unexpected structure."
        )

    # Re-sign (zip strips code signatures)
    _codesign(framework_dir)

    # Architecture check
    arch = platform.machine()
    result = subprocess.run(
        ["lipo", "-info", str(binary)], capture_output=True, text=True
    )
    if result.returncode == 0 and arch not in result.stdout:
        print(
            f"  warning: downloaded dylib may not match your architecture ({arch})",
            file=sys.stderr,
        )

    print(f"  cached at {binary}", file=sys.stderr)
    return str(binary)

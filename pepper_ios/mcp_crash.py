"""Crash log parsing and fetching for Pepper MCP."""

import asyncio
import json
import os

from .pepper_common import get_config


def parse_crash_report(path: str, content: str) -> str:
    """Parse a .ips crash report and return a concise summary."""
    try:
        # .ips format: JSON header on line 1, JSON body on line 2+
        lines = content.split("\n", 1)
        header = json.loads(lines[0])
        body = json.loads(lines[1]) if len(lines) > 1 and lines[1].strip().startswith("{") else None

        parts = []
        app_name = header.get("app_name", header.get("name", ""))
        if app_name:
            parts.append(f"Process: {app_name}")

        if body:
            # Exception info
            exc = body.get("exception", {})
            exc_type = exc.get("type", "")
            exc_signal = exc.get("signal", "")
            exc_subtype = exc.get("subtype", "")
            termination = body.get("termination", {})
            term_reason = termination.get("description", "")

            if exc_type:
                parts.append(f"Exception: {exc_type}" + (f" ({exc_signal})" if exc_signal else ""))
            if exc_subtype:
                parts.append(f"Subtype: {exc_subtype}")
            if term_reason:
                parts.append(f"Reason: {term_reason}")

            # NSException / ASI (Application Specific Information)
            asi = body.get("asi", body.get("lastExceptionBacktrace"))
            if isinstance(asi, dict):
                for _key, val in asi.items():
                    if isinstance(val, list):
                        parts.append(f"NSException: {' '.join(str(v) for v in val[:3])}")
                    elif isinstance(val, str):
                        parts.append(f"NSException: {val[:200]}")

            # Crashed thread stack trace
            threads = body.get("threads", [])
            triggered = None
            for t in threads:
                if t.get("triggered", False):
                    triggered = t
                    break
            if triggered:
                frames = triggered.get("frames", [])[:10]
                # Resolve image names
                images = body.get("usedImages", [])
                frame_lines = []
                for i, f in enumerate(frames):
                    symbol = f.get("symbol", "???")
                    img_idx = f.get("imageIndex", -1)
                    img_name = ""
                    if 0 <= img_idx < len(images):
                        img_path = images[img_idx].get("name", images[img_idx].get("path", ""))
                        img_name = os.path.basename(img_path) if img_path else ""
                    offset = f.get("imageOffset", 0)
                    if symbol and symbol != "???":
                        frame_lines.append(f"  {i}: {img_name}  {symbol}")
                    else:
                        frame_lines.append(f"  {i}: {img_name}  +{offset}")
                if frame_lines:
                    thread_name = triggered.get("name", f"Thread {triggered.get('id', '?')}")
                    parts.append(f"Crashed thread ({thread_name}):\n" + "\n".join(frame_lines))
        else:
            # Couldn't parse body — show raw header info
            exc_type = header.get("exception_type", "")
            if exc_type:
                parts.append(f"Exception: {exc_type}")

        if parts:
            return "\n--- CRASH LOG ---\n" + "\n".join(parts) + f"\nFull report: {path}"
    except (json.JSONDecodeError, KeyError, IndexError):
        # Fall back to raw content
        raw_lines = content.split("\n")[:15]
        return "\n--- CRASH LOG (raw) ---\n" + "\n".join(raw_lines) + f"\n...\nFull report: {path}"
    return ""


async def fetch_crash_info(sim_udid: str) -> str:
    """Fetch recent crash log after APP CRASHED. Waits briefly for crash report generation."""
    import time

    cfg = get_config()
    bundle_id = cfg.get("bundle_id", "")
    app_name_hint = bundle_id.rsplit(".", 1)[-1].lower() if bundle_id else ""

    reports_dir = os.path.expanduser("~/Library/Logs/DiagnosticReports")
    if not os.path.isdir(reports_dir):
        return ""

    # Wait for crash report to be written
    await asyncio.sleep(1.5)

    # Find .ips files from the last 15 seconds
    cutoff = time.time() - 15
    candidates = []
    try:
        for entry in os.scandir(reports_dir):
            if entry.name.endswith(".ips"):
                try:
                    mtime = entry.stat().st_mtime
                    if mtime >= cutoff:
                        candidates.append((mtime, entry.path))
                except OSError:
                    pass
    except OSError:
        return ""

    if not candidates:
        return ""

    candidates.sort(reverse=True)

    # Try to find one matching our bundle ID or app name
    for _, path in candidates[:5]:
        try:
            with open(path) as f:
                content = f.read()
            if bundle_id and bundle_id in content:
                return parse_crash_report(path, content)
            # Fallback: match by app name in filename or header
            if app_name_hint:
                fname_lower = os.path.basename(path).lower()
                if fname_lower.startswith(app_name_hint + "-") or fname_lower.startswith(app_name_hint + "_"):
                    return parse_crash_report(path, content)
                try:
                    header = json.loads(content.split("\n", 1)[0])
                    if header.get("app_name", "").lower() == app_name_hint:
                        return parse_crash_report(path, content)
                except (json.JSONDecodeError, IndexError):
                    pass
        except OSError:
            continue

    # No bundle/name match — use most recent (likely ours if it just crashed)
    try:
        with open(candidates[0][1]) as f:
            content = f.read()
        return parse_crash_report(candidates[0][1], content)
    except OSError:
        return ""

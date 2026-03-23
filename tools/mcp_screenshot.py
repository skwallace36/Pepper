"""Screenshot capture for Pepper MCP — in-process fast path + simctl fallback."""

import asyncio
import base64
import os
import tempfile


async def capture_screenshot_inprocess(
    send_command, port: int, quality: str = "standard",
    element: str | None = None, text: str | None = None,
    host: str = "localhost",
) -> str | None:
    """In-process screenshot via the dylib's screenshot handler.

    Much faster than simctl — renders directly inside the app process with no
    IPC, temp files, or sips conversion. Supports per-view snapshots.

    Returns base64-encoded JPEG string, or None on failure.
    """
    params: dict = {"quality": quality, "scale": "1x"}
    if element is not None:
        params["element"] = element
    if text is not None:
        params["text"] = text
    try:
        resp = await send_command(port, "screenshot", params, timeout=5, host=host)
        if resp.get("status") == "error":
            return None
        data = resp.get("data", resp)
        return data.get("image")
    except Exception:
        return None


async def capture_screenshot(udid: str, quality: str = "standard") -> str | None:
    """Capture simulator screenshot via simctl. Returns base64-encoded image.

    Fallback path when in-process capture is unavailable. Returns None on failure.

    quality:
      "standard" — 1x resize, 70% JPEG (for inline look augmentation)
      "high"     — 1x resize, 95% JPEG (for PR validation / GitHub posting)
    """
    png_path = None
    out_path = None
    try:
        # Create temp files
        fd, png_path = tempfile.mkstemp(suffix='.png', prefix='pepper-vis-')
        os.close(fd)

        # Capture screenshot
        proc = await asyncio.create_subprocess_exec(
            'xcrun', 'simctl', 'io', udid, 'screenshot', png_path,
            stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.DEVNULL,
        )
        await asyncio.wait_for(proc.wait(), timeout=5)
        if proc.returncode != 0:
            return None

        # Get actual image height and derive 1x logical height (divide by scale factor)
        height_proc = await asyncio.create_subprocess_exec(
            'sips', '-g', 'pixelHeight', png_path,
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL,
        )
        height_out, _ = await height_proc.communicate()
        # sips output: "  pixelHeight: 1748\n" — extract the number
        logical_height = 874  # fallback
        for line in height_out.decode().splitlines():
            if 'pixelHeight' in line:
                try:
                    px = int(line.split(':')[-1].strip())
                    # Common scales: 2x (most sims) or 3x (Plus models)
                    # Divide by 2 for standard retina; if result > 1000, likely 3x
                    h2 = px // 2
                    logical_height = h2 if h2 <= 1000 else px // 3
                except (ValueError, IndexError):
                    pass
                break

        if quality == "high":
            # High quality: 1x resize, 95% JPEG
            out_path = png_path.replace('.png', '-hq.jpg')
            proc = await asyncio.create_subprocess_exec(
                'sips', '-Z', str(logical_height), '-s', 'format', 'jpeg',
                '-s', 'formatOptions', '95',
                png_path, '--out', out_path,
                stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.DEVNULL,
            )
        else:
            # Standard: 1x resize, 70% JPEG
            out_path = png_path.replace('.png', '.jpg')
            proc = await asyncio.create_subprocess_exec(
                'sips', '-Z', str(logical_height), '-s', 'format', 'jpeg',
                '-s', 'formatOptions', '70',
                png_path, '--out', out_path,
                stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.DEVNULL,
            )

        await asyncio.wait_for(proc.wait(), timeout=5)
        if proc.returncode != 0:
            return None

        with open(out_path, 'rb') as f:
            return base64.b64encode(f.read()).decode('ascii')
    except (TimeoutError, OSError):
        return None
    finally:
        for p in [png_path, out_path]:
            if p:
                try:
                    os.unlink(p)
                except OSError:
                    pass

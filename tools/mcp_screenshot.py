"""Screenshot capture for Pepper MCP — simctl + sips pipeline."""

import asyncio
import base64
import os
import tempfile
from typing import Optional


async def capture_screenshot(udid: str, quality: str = "standard") -> Optional[str]:
    """Capture simulator screenshot. Returns base64-encoded image. Returns None on failure.

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
    except Exception:
        return None
    finally:
        for p in [png_path, out_path]:
            if p:
                try:
                    os.unlink(p)
                except OSError:
                    pass

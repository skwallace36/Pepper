"""Screen recording tool definition for Pepper MCP.

Tool definition for: record (start/stop simulator recording, mp4/gif output).
"""
from __future__ import annotations

import asyncio
import os
import signal
import time

from pepper_common import discover_instance
from pydantic import Field

# Active recording sessions: UDID → {"proc": subprocess, "path": str, "start_time": float}
_active_recordings: dict = {}


def register_record_tools(mcp):
    """Register screen recording tools on the given MCP server.

    Args:
        mcp: FastMCP server instance.
    """

    @mcp.tool()
    async def record(
        simulator: str | None = Field(default=None, description="Simulator UDID"),
        action: str = Field(description="Action: start, stop"),
        output: str | None = Field(default=None, description="Output path for stop (default: /tmp/pepper-recording.mp4). Use .gif extension for GIF output."),
        fps: int = Field(default=12, description="GIF frame rate, ignored for mp4 (default: 12)"),
    ) -> str:
        """Record the simulator screen. Outputs mp4 (default) or GIF (if output ends in .gif).

        Start/stop workflow:
          1. record action=start
          2. (do your interactions — tap, scroll, navigate, etc.)
          3. record action=stop output=/tmp/my-recording.mp4

        Upload videos to GitHub via Playwright MCP (browser automation) for autoplay in PRs.
        Upload GIFs/screenshots via upload-screenshot tool (release assets)."""
        try:
            _host, _port, udid = discover_instance(simulator)
        except RuntimeError as e:
            return str(e)

        if action == "start":
            # Stop any existing recording on this sim
            if udid in _active_recordings:
                try:
                    _active_recordings[udid]["proc"].send_signal(signal.SIGINT)
                    _active_recordings[udid]["proc"].wait(timeout=5)
                except OSError:
                    pass
                del _active_recordings[udid]

            video_path = f"/tmp/pepper-recording-{udid[:8]}.mp4"
            try:
                os.unlink(video_path)
            except FileNotFoundError:
                pass

            proc = await asyncio.create_subprocess_exec(
                "xcrun", "simctl", "io", udid, "recordVideo",
                "--display", "internal", "--codec", "h264", video_path,
                stdout=asyncio.subprocess.DEVNULL,
                stderr=asyncio.subprocess.DEVNULL,
            )
            _active_recordings[udid] = {
                "proc": proc,
                "path": video_path,
                "start_time": time.time(),
            }
            return f"Recording started on {udid[:8]}. Do your interactions, then `record action=stop`."

        elif action == "stop":
            if udid not in _active_recordings:
                return "No active recording on this simulator. Use `record action=start` first."

            session = _active_recordings.pop(udid)
            proc = session["proc"]
            video_path = session["path"]
            duration = time.time() - session["start_time"]

            # Send SIGINT to stop recording gracefully
            proc.send_signal(signal.SIGINT)
            try:
                await asyncio.wait_for(proc.wait(), timeout=10)
            except TimeoutError:
                proc.kill()
                return "Recording process didn't stop cleanly."

            if not os.path.exists(video_path):
                return "Recording failed — no video file produced."

            out_path = output or "/tmp/pepper-recording.mp4"
            is_gif = out_path.endswith(".gif")

            if is_gif:
                # Convert to GIF — small for inline display
                ffmpeg_proc = await asyncio.create_subprocess_exec(
                    "ffmpeg", "-y", "-i", video_path,
                    "-vf", f"fps={fps},scale=300:-1:flags=lanczos",
                    "-loop", "0", out_path,
                    stdout=asyncio.subprocess.DEVNULL,
                    stderr=asyncio.subprocess.DEVNULL,
                )
            else:
                # Compress mp4 — keep native resolution, high quality
                ffmpeg_proc = await asyncio.create_subprocess_exec(
                    "ffmpeg", "-y", "-i", video_path,
                    "-c:v", "libx264", "-crf", "20", "-preset", "slow",
                    "-pix_fmt", "yuv420p", "-an",
                    out_path,
                    stdout=asyncio.subprocess.DEVNULL,
                    stderr=asyncio.subprocess.DEVNULL,
                )

            await asyncio.wait_for(ffmpeg_proc.wait(), timeout=30)

            if not os.path.exists(out_path):
                return f"Conversion failed. Raw video at {video_path}"

            out_size = os.path.getsize(out_path) / 1024
            result = f"Recording saved: {out_path} ({out_size:.0f}KB, {duration:.1f}s)"

            # Clean up raw video
            try:
                os.unlink(video_path)
            except OSError:
                pass

            if is_gif:
                result += "\nUpload GIFs via: upload-screenshot --repo <repo> <file>"
            else:
                result += "\nUpload videos via Playwright MCP for autoplay in PRs (see /validate-pr skill)."

            return result

        return "Unknown action. Use start or stop."

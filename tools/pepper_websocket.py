"""pepper_websocket -- shared WebSocket communication for Pepper tools.

Provides make_command(), recv_response(), and send_command() used by
pepper-mcp, pepper-ctl, pepper-stream, and test-client.py.
"""

import asyncio
import json
import uuid

from pepper_ws_raw import RawWebSocket


def make_command(cmd, params=None):
    """Build a command message with a short unique id."""
    msg = {"id": str(uuid.uuid4())[:8], "cmd": cmd}
    if params:
        msg["params"] = params
    return msg


class CrashError(Exception):
    """Raised when the app crashes (WebSocket connection lost)."""

    def __init__(self, cmd, detail=""):
        self.cmd = cmd
        self.detail = detail
        super().__init__(
            f"APP CRASHED. The '{cmd}' command caused the app to crash "
            f"(WebSocket connection lost{': ' + detail if detail else ''}). "
            f"Investigate the crash before retrying."
        )


def _send_command_sync(host, port, msg, timeout=10, on_event=None):
    """Synchronous send_command using raw WebSocket (no external deps)."""
    msg_id = msg.get("id")
    ws = RawWebSocket.connect(host, port, timeout=timeout)
    try:
        ws.send(json.dumps(msg))
        import time
        deadline = time.monotonic() + timeout
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError()
            raw = ws.recv(timeout=remaining)
            data = json.loads(raw)
            if "event" in data:
                if on_event:
                    on_event(data["event"], data.get("data", {}))
                continue
            if msg_id is None or data.get("id") == msg_id:
                return data
    except (ConnectionError, ConnectionResetError, BrokenPipeError, OSError) as e:
        raise CrashError(msg.get("cmd", "unknown"), detail=str(e)) from e
    finally:
        ws.close()


async def send_command(host, port, msg, timeout=10, on_event=None, close_timeout=2):
    """Open a connection, send *msg*, and return the matching response.

    Uses a raw stdlib WebSocket client (no external library dependency).

    Raises ``CrashError`` on connection loss.
    Raises ``ConnectionRefusedError`` if the server is unreachable.
    Raises ``asyncio.TimeoutError`` if no response within *timeout*.
    """
    return await asyncio.get_running_loop().run_in_executor(
        None, lambda: _send_command_sync(host, port, msg, timeout, on_event)
    )

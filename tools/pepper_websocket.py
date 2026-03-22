"""pepper_websocket -- shared WebSocket communication for Pepper tools.

Provides make_command(), recv_response(), and send_command() used by
pepper-mcp, pepper-ctl, pepper-stream, and test-client.py.
"""

import asyncio
import json
import uuid

import websockets


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


async def recv_response(ws, msg_id, timeout=10, on_event=None):
    """Read from *ws* until a response matching *msg_id* arrives.

    Filters out event messages.  If *on_event* is provided it is called
    as ``on_event(event_name, event_data)`` for every event received.

    Returns the response dict.

    Raises ``asyncio.TimeoutError`` if *timeout* expires.
    Raises ``CrashError`` if the connection drops (wraps ConnectionClosed).
    """
    deadline = asyncio.get_event_loop().time() + timeout
    try:
        while True:
            remaining = deadline - asyncio.get_event_loop().time()
            if remaining <= 0:
                raise asyncio.TimeoutError()
            raw = await asyncio.wait_for(ws.recv(), timeout=remaining)
            data = json.loads(raw)
            # Skip event messages
            if "event" in data:
                if on_event:
                    on_event(data["event"], data.get("data", {}))
                continue
            # Accept response matching our id, or any non-event response
            if msg_id is None or data.get("id") == msg_id:
                return data
    except (
        websockets.exceptions.ConnectionClosed,
        websockets.exceptions.ConnectionClosedError,
        ConnectionResetError,
        BrokenPipeError,
    ):
        raise CrashError(msg_id or "unknown")


async def send_command(host, port, msg, timeout=10, on_event=None, close_timeout=2):
    """Open a connection, send *msg*, and return the matching response.

    Raises ``CrashError`` on connection loss.
    Raises ``ConnectionRefusedError`` if the server is unreachable.
    Raises ``asyncio.TimeoutError`` if no response within *timeout*.
    """
    url = f"ws://{host}:{port}"
    msg_id = msg.get("id")
    try:
        async with websockets.connect(url, close_timeout=close_timeout, compression=None) as ws:
            await ws.send(json.dumps(msg))
            return await recv_response(ws, msg_id, timeout=timeout, on_event=on_event)
    except (
        websockets.exceptions.ConnectionClosed,
        websockets.exceptions.ConnectionClosedError,
        ConnectionResetError,
        BrokenPipeError,
    ):
        raise CrashError(msg.get("cmd", "unknown"))

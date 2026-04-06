"""pepper_websocket -- shared WebSocket communication for Pepper tools.

Provides make_command(), recv_response(), and send_command() used by
pepper-mcp, pepper-ctl, pepper-stream, and test-client.py.
"""

import asyncio
import json
import logging
import time
import uuid

from .pepper_ws_raw import RawWebSocket

logger = logging.getLogger("pepper_ws")

# Retryable errors: transient connection problems where the server may
# come back (e.g. app backgrounded briefly, network hiccup).
# CrashError is NOT retried — it means the app is gone.
_RETRYABLE = (ConnectionRefusedError, ConnectionResetError, TimeoutError, OSError)


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


def _send_with_retry(host, port, msg, timeout=10, on_event=None, retries=0):
    """Send with retry for transient connection failures.

    Retries on ConnectionRefusedError, ConnectionResetError, TimeoutError,
    and OSError. CrashError (mid-command connection loss) is never retried.
    Uses exponential backoff: 0.5s, 1s, 2s, ...
    """
    last_err = None
    for attempt in range(1 + retries):
        try:
            return _send_command_sync(host, port, msg, timeout, on_event)
        except CrashError:
            raise  # App crashed — don't retry
        except _RETRYABLE as e:
            last_err = e
            if attempt < retries:
                delay = 0.5 * (2 ** attempt)
                logger.debug(
                    "retry %d/%d for cmd=%s after %s (delay=%.1fs)",
                    attempt + 1, retries, msg.get("cmd"), type(e).__name__, delay,
                )
                time.sleep(delay)
    raise last_err  # type: ignore[misc]


# Public sync API for callers that don't need asyncio (e.g. test runner).
send_command_sync = _send_with_retry


async def send_command(host, port, msg, timeout=10, on_event=None, close_timeout=2, retries=0):
    """Open a connection, send *msg*, and return the matching response.

    Uses a raw stdlib WebSocket client (no external library dependency).

    Args:
        retries: Number of retry attempts for transient connection failures
                 (ConnectionRefusedError, TimeoutError, etc.). Default 0 (no retry).
                 CrashError is never retried.

    Raises ``CrashError`` on connection loss.
    Raises ``ConnectionRefusedError`` if the server is unreachable.
    Raises ``asyncio.TimeoutError`` if no response within *timeout*.
    """
    return await asyncio.get_running_loop().run_in_executor(
        None, lambda: _send_with_retry(host, port, msg, timeout, on_event, retries)
    )

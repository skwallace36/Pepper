"""Tests for WebSocket reconnection, retry logic, and monitor state management."""

from __future__ import annotations

import asyncio
import importlib.util
from unittest.mock import patch

import pytest

import pepper_ios.pepper_websocket as ws
from pepper_ios.pepper_websocket import CrashError, _send_with_retry, make_command

# ---------------------------------------------------------------------------
# make_command
# ---------------------------------------------------------------------------


class TestMakeCommand:
    def test_basic(self):
        msg = make_command("ping")
        assert msg["cmd"] == "ping"
        assert "id" in msg
        assert len(msg["id"]) == 8

    def test_with_params(self):
        msg = make_command("look", {"mode": "map"})
        assert msg["params"] == {"mode": "map"}

    def test_no_params_key_when_none(self):
        msg = make_command("status")
        assert "params" not in msg


# ---------------------------------------------------------------------------
# CrashError
# ---------------------------------------------------------------------------


class TestCrashError:
    def test_message_format(self):
        err = CrashError("tap", detail="Connection reset")
        assert "APP CRASHED" in str(err)
        assert "tap" in str(err)
        assert "Connection reset" in str(err)
        assert err.cmd == "tap"

    def test_no_detail(self):
        err = CrashError("look")
        assert "APP CRASHED" in str(err)
        assert "look" in str(err)


# ---------------------------------------------------------------------------
# _send_with_retry
# ---------------------------------------------------------------------------


class TestSendWithRetry:
    """Test retry logic for transient connection failures."""

    def test_no_retry_on_success(self):
        """Successful send should not retry."""
        with patch.object(ws, "_send_command_sync", return_value={"status": "ok"}) as mock:
            result = _send_with_retry("localhost", 9999, {"cmd": "ping", "id": "abc"})
            assert result == {"status": "ok"}
            assert mock.call_count == 1

    def test_no_retry_when_retries_zero(self):
        """With retries=0, failure propagates immediately."""
        with (
            patch.object(ws, "_send_command_sync", side_effect=ConnectionRefusedError("refused")),
            pytest.raises(ConnectionRefusedError),
        ):
            _send_with_retry("localhost", 9999, {"cmd": "ping", "id": "abc"}, retries=0)

    def test_retry_on_connection_refused(self):
        """ConnectionRefusedError should be retried."""
        call_count = 0

        def fake_send(*args, **kwargs):
            nonlocal call_count
            call_count += 1
            if call_count < 3:
                raise ConnectionRefusedError("refused")
            return {"status": "ok"}

        with patch.object(ws, "_send_command_sync", side_effect=fake_send), patch("time.sleep"):
            result = _send_with_retry("localhost", 9999, {"cmd": "ping", "id": "abc"}, retries=3)
            assert result == {"status": "ok"}
            assert call_count == 3

    def test_retry_on_timeout(self):
        """TimeoutError should be retried."""
        call_count = 0

        def fake_send(*args, **kwargs):
            nonlocal call_count
            call_count += 1
            if call_count == 1:
                raise TimeoutError("timed out")
            return {"status": "ok"}

        with patch.object(ws, "_send_command_sync", side_effect=fake_send), patch("time.sleep"):
            result = _send_with_retry("localhost", 9999, {"cmd": "status", "id": "abc"}, retries=2)
            assert result == {"status": "ok"}
            assert call_count == 2

    def test_retry_on_os_error(self):
        """OSError (e.g. network hiccup) should be retried."""
        call_count = 0

        def fake_send(*args, **kwargs):
            nonlocal call_count
            call_count += 1
            if call_count == 1:
                raise OSError("network unreachable")
            return {"status": "ok"}

        with patch.object(ws, "_send_command_sync", side_effect=fake_send), patch("time.sleep"):
            result = _send_with_retry("localhost", 9999, {"cmd": "look", "id": "abc"}, retries=1)
            assert result == {"status": "ok"}

    def test_no_retry_on_crash(self):
        """CrashError should NOT be retried — the app is gone."""
        with (
            patch.object(ws, "_send_command_sync", side_effect=CrashError("tap")),
            pytest.raises(CrashError),
        ):
            _send_with_retry("localhost", 9999, {"cmd": "tap", "id": "abc"}, retries=3)

    def test_exhausted_retries_raises_last_error(self):
        """When all retries fail, the last error propagates."""
        with (
            patch.object(ws, "_send_command_sync", side_effect=ConnectionRefusedError("refused")),
            patch("time.sleep"),
            pytest.raises(ConnectionRefusedError),
        ):
            _send_with_retry("localhost", 9999, {"cmd": "ping", "id": "abc"}, retries=2)

    def test_exponential_backoff_delays(self):
        """Verify backoff delays: 0.5s, 1s, 2s, ..."""
        delays = []

        with (
            patch.object(ws, "_send_command_sync", side_effect=ConnectionRefusedError("refused")),
            patch("time.sleep", side_effect=lambda d: delays.append(d)),
            pytest.raises(ConnectionRefusedError),
        ):
            _send_with_retry("localhost", 9999, {"cmd": "ping", "id": "abc"}, retries=3)

        assert len(delays) == 3
        assert delays[0] == pytest.approx(0.5)
        assert delays[1] == pytest.approx(1.0)
        assert delays[2] == pytest.approx(2.0)


# ---------------------------------------------------------------------------
# Monitor state reset
# ---------------------------------------------------------------------------

_has_mcp = importlib.util.find_spec("mcp") is not None
_skip_no_mcp = pytest.mark.skipif(not _has_mcp, reason="mcp package not installed")


@_skip_no_mcp
class TestMonitorStateReset:
    """Test that monitor state resets on reconnection/deploy."""

    def test_reset_clears_known_monitors(self):
        """reset_monitor_state sets _known_active_monitors back to None."""
        import pepper_ios.mcp_server as srv

        # Simulate a previous session that discovered active monitors
        srv._known_active_monitors = frozenset({"network", "console"})
        assert srv._known_active_monitors is not None

        srv.reset_monitor_state()
        assert srv._known_active_monitors is None

    def test_reset_is_idempotent(self):
        """Calling reset when already None is a no-op."""
        import pepper_ios.mcp_server as srv

        srv._known_active_monitors = None
        srv.reset_monitor_state()  # should not raise
        assert srv._known_active_monitors is None


# ---------------------------------------------------------------------------
# send_command async wrapper
# ---------------------------------------------------------------------------


class TestSendCommandAsync:
    """Test the async send_command wrapper passes retries through."""

    def test_retries_parameter_passed(self):
        """Verify retries kwarg reaches _send_with_retry."""
        with patch.object(ws, "_send_with_retry", return_value={"status": "ok"}) as mock:
            loop = asyncio.new_event_loop()
            try:
                msg = make_command("ping")
                result = loop.run_until_complete(ws.send_command("localhost", 9999, msg, retries=3))
                assert result == {"status": "ok"}
                # _send_with_retry is called via positional args from the lambda
                args = mock.call_args[0]
                # The lambda passes: host, port, msg, timeout, on_event, retries
                assert args[-1] == 3  # retries parameter
            finally:
                loop.close()


# ---------------------------------------------------------------------------
# MCP send_command error handling
# ---------------------------------------------------------------------------


@_skip_no_mcp
class TestMcpSendCommand:
    """Test MCP-level send_command error handling and retries passthrough."""

    def test_connection_refused_returns_error_dict(self):
        """ConnectionRefusedError returns a structured error dict."""
        import pepper_ios.mcp_server as srv

        async def run():
            with patch.object(ws, "_send_with_retry", side_effect=ConnectionRefusedError("refused")):
                return await srv.send_command(9999, "ping")

        result = asyncio.new_event_loop().run_until_complete(run())
        assert result["status"] == "error"
        assert "Connection refused" in result["error"]

    def test_crash_error_returns_error_dict(self):
        """CrashError returns a structured error dict with crash info."""
        import pepper_ios.mcp_server as srv

        async def run():
            with patch.object(ws, "_send_with_retry", side_effect=CrashError("tap")):
                return await srv.send_command(9999, "tap")

        result = asyncio.new_event_loop().run_until_complete(run())
        assert result["status"] == "error"
        assert "APP CRASHED" in result["error"]

    def test_timeout_returns_error_dict(self):
        """Timeout returns a structured error dict."""
        import pepper_ios.mcp_server as srv

        async def run():
            with patch.object(ws, "_send_with_retry", side_effect=asyncio.TimeoutError()):
                return await srv.send_command(9999, "status")

        result = asyncio.new_event_loop().run_until_complete(run())
        assert result["status"] == "error"
        assert "timed out" in result["error"]

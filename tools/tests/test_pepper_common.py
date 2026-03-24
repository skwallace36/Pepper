"""Unit tests for pepper_common.py — port discovery, .env loading, JSON parsing."""
from __future__ import annotations

import os

import pepper_common as pc
import pytest

# ---------------------------------------------------------------------------
# try_parse_json
# ---------------------------------------------------------------------------

class TestTryParseJson:
    def test_none_returns_none(self):
        assert pc.try_parse_json(None) is None

    def test_valid_string(self):
        assert pc.try_parse_json('"hello"') == "hello"

    def test_valid_int(self):
        assert pc.try_parse_json("42") == 42

    def test_valid_bool_true(self):
        assert pc.try_parse_json("true") is True

    def test_valid_bool_false(self):
        assert pc.try_parse_json("false") is False

    def test_valid_dict(self):
        assert pc.try_parse_json('{"a": 1}') == {"a": 1}

    def test_valid_list(self):
        assert pc.try_parse_json("[1, 2, 3]") == [1, 2, 3]

    def test_invalid_json_returns_original(self):
        assert pc.try_parse_json("not-json") == "not-json"

    def test_already_non_string_int(self):
        # Non-string values that aren't JSON-parseable fall back to original
        assert pc.try_parse_json(123) == 123

    def test_already_non_string_dict(self):
        d = {"x": 1}
        assert pc.try_parse_json(d) == d


# ---------------------------------------------------------------------------
# require_parse_json
# ---------------------------------------------------------------------------

class TestRequireParseJson:
    def test_valid_json(self):
        assert pc.require_parse_json('{"key": "val"}') == {"key": "val"}

    def test_valid_list(self):
        assert pc.require_parse_json("[1,2,3]") == [1, 2, 3]

    def test_invalid_raises_value_error(self):
        with pytest.raises(ValueError, match="must be valid JSON"):
            pc.require_parse_json("oops", field_name="params")

    def test_error_includes_field_name(self):
        with pytest.raises(ValueError, match="my_field"):
            pc.require_parse_json("{bad", field_name="my_field")


# ---------------------------------------------------------------------------
# load_env
# ---------------------------------------------------------------------------

class TestLoadEnv:
    def test_missing_file_returns_empty(self, tmp_path, monkeypatch):
        monkeypatch.setattr(pc, "PEPPER_DIR", str(tmp_path))
        assert pc.load_env() == {}

    def test_basic_key_value(self, tmp_path, monkeypatch):
        (tmp_path / ".env").write_text("APP_SCHEME=MyApp\n")
        monkeypatch.setattr(pc, "PEPPER_DIR", str(tmp_path))
        assert pc.load_env() == {"APP_SCHEME": "MyApp"}

    def test_skips_comments(self, tmp_path, monkeypatch):
        (tmp_path / ".env").write_text("# comment\nAPP_SCHEME=MyApp\n")
        monkeypatch.setattr(pc, "PEPPER_DIR", str(tmp_path))
        assert pc.load_env() == {"APP_SCHEME": "MyApp"}

    def test_skips_blank_lines(self, tmp_path, monkeypatch):
        (tmp_path / ".env").write_text("\nAPP_SCHEME=MyApp\n\n")
        monkeypatch.setattr(pc, "PEPPER_DIR", str(tmp_path))
        assert pc.load_env() == {"APP_SCHEME": "MyApp"}

    def test_skips_lines_without_equals(self, tmp_path, monkeypatch):
        (tmp_path / ".env").write_text("NOEQUALS\nAPP_SCHEME=MyApp\n")
        monkeypatch.setattr(pc, "PEPPER_DIR", str(tmp_path))
        assert pc.load_env() == {"APP_SCHEME": "MyApp"}

    def test_strips_single_quotes(self, tmp_path, monkeypatch):
        (tmp_path / ".env").write_text("APP_SCHEME='MyApp'\n")
        monkeypatch.setattr(pc, "PEPPER_DIR", str(tmp_path))
        assert pc.load_env() == {"APP_SCHEME": "MyApp"}

    def test_strips_double_quotes(self, tmp_path, monkeypatch):
        (tmp_path / ".env").write_text('APP_SCHEME="MyApp"\n')
        monkeypatch.setattr(pc, "PEPPER_DIR", str(tmp_path))
        assert pc.load_env() == {"APP_SCHEME": "MyApp"}

    def test_multiple_keys(self, tmp_path, monkeypatch):
        (tmp_path / ".env").write_text("A=1\nB=2\nC=3\n")
        monkeypatch.setattr(pc, "PEPPER_DIR", str(tmp_path))
        assert pc.load_env() == {"A": "1", "B": "2", "C": "3"}

    def test_value_with_equals(self, tmp_path, monkeypatch):
        # Only first '=' is the separator; value may contain '='
        (tmp_path / ".env").write_text("URL=http://host:8080/path?x=1\n")
        monkeypatch.setattr(pc, "PEPPER_DIR", str(tmp_path))
        assert pc.load_env() == {"URL": "http://host:8080/path?x=1"}


# ---------------------------------------------------------------------------
# port_alive
# ---------------------------------------------------------------------------

class TestPortAlive:
    def test_closed_port_returns_false(self):
        # Port 1 is almost certainly not open on localhost
        assert pc.port_alive(1, timeout=0.1) is False

    def test_open_port_returns_true(self, tmp_path):
        import socket
        import threading

        # Bind to an ephemeral port to guarantee something is listening
        server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        server.bind(("localhost", 0))
        server.listen(1)
        port = server.getsockname()[1]

        def accept_once():
            try:
                conn, _ = server.accept()
                conn.close()
            except OSError:
                pass

        t = threading.Thread(target=accept_once, daemon=True)
        t.start()
        try:
            assert pc.port_alive(port, timeout=1.0) is True
        finally:
            server.close()
            t.join(timeout=1)


# ---------------------------------------------------------------------------
# discover_port / _resolve_port_file
# ---------------------------------------------------------------------------

class TestDiscoverPort:
    def _write_port_file(self, port_dir, udid, port):
        os.makedirs(port_dir, exist_ok=True)
        with open(os.path.join(port_dir, f"{udid}.port"), "w") as f:
            f.write(str(port))

    def test_fallback_when_no_port_dir(self, tmp_path, monkeypatch):
        monkeypatch.setattr(pc, "PORT_DIR", str(tmp_path / "missing"))
        result = pc.discover_port(fallback=9999)
        assert result == 9999

    def test_raises_without_fallback_when_no_port_dir(self, tmp_path, monkeypatch):
        monkeypatch.setattr(pc, "PORT_DIR", str(tmp_path / "missing"))
        with pytest.raises(RuntimeError, match="No Pepper instances"):
            pc.discover_port()

    def test_specific_simulator_missing_file(self, tmp_path, monkeypatch):
        monkeypatch.setattr(pc, "PORT_DIR", str(tmp_path))
        with pytest.raises(RuntimeError, match="No port file for simulator"):
            pc.discover_port(simulator="NONEXISTENT-UDID")

    def test_multiple_live_ports_raises(self, tmp_path, monkeypatch):
        import socket

        # Spin up two listening sockets
        servers = []
        ports = []
        for _ in range(2):
            s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            s.bind(("localhost", 0))
            s.listen(1)
            servers.append(s)
            ports.append(s.getsockname()[1])

        port_dir = str(tmp_path / "ports")
        os.makedirs(port_dir)
        for i, port in enumerate(ports):
            self._write_port_file(port_dir, f"UDID-{i}", port)

        monkeypatch.setattr(pc, "PORT_DIR", port_dir)
        monkeypatch.setattr(pc, "port_alive", lambda p, host="localhost", timeout=1.0: p in ports)

        try:
            with pytest.raises(RuntimeError, match="Multiple simulators"):
                pc.discover_port()
        finally:
            for s in servers:
                s.close()

    def test_stale_port_file_cleaned_up(self, tmp_path, monkeypatch):
        port_dir = str(tmp_path / "ports")
        os.makedirs(port_dir)
        stale_path = os.path.join(port_dir, "DEAD-UDID.port")
        with open(stale_path, "w") as f:
            f.write("9876")

        monkeypatch.setattr(pc, "PORT_DIR", port_dir)
        # port 9876 is dead — discover_port with fallback should clean up and return fallback
        result = pc.discover_port(fallback=1234)
        assert result == 1234
        assert not os.path.exists(stale_path)


# ---------------------------------------------------------------------------
# list_simulators
# ---------------------------------------------------------------------------

class TestListSimulators:
    def test_empty_when_no_port_dir(self, tmp_path, monkeypatch):
        monkeypatch.setattr(pc, "PORT_DIR", str(tmp_path / "missing"))
        assert pc.list_simulators() == []

    def test_empty_when_all_ports_stale(self, tmp_path, monkeypatch):
        port_dir = str(tmp_path / "ports")
        os.makedirs(port_dir)
        with open(os.path.join(port_dir, "UDID-A.port"), "w") as f:
            f.write("9999")
        monkeypatch.setattr(pc, "PORT_DIR", port_dir)
        monkeypatch.setattr(pc, "port_alive", lambda p, host="localhost", timeout=1.0: False)
        assert pc.list_simulators() == []

    def test_ignores_non_port_files(self, tmp_path, monkeypatch):
        port_dir = str(tmp_path / "ports")
        os.makedirs(port_dir)
        with open(os.path.join(port_dir, "notes.txt"), "w") as f:
            f.write("hello")
        monkeypatch.setattr(pc, "PORT_DIR", port_dir)
        assert pc.list_simulators() == []


# ---------------------------------------------------------------------------
# register_device / unregister_device / _read_device_file
# ---------------------------------------------------------------------------

class TestDeviceRegistration:
    def test_register_and_read(self, tmp_path, monkeypatch):
        monkeypatch.setattr(pc, "DEVICE_DIR", str(tmp_path / "devices"))
        pc.register_device("MY-UDID", "192.168.1.1", 8765)
        data = pc._read_device_file("MY-UDID")
        assert data is not None
        assert data["host"] == "192.168.1.1"
        assert data["port"] == 8765
        assert data["udid"] == "MY-UDID"

    def test_register_with_name_and_via(self, tmp_path, monkeypatch):
        monkeypatch.setattr(pc, "DEVICE_DIR", str(tmp_path / "devices"))
        pc.register_device("MY-UDID", "192.168.1.1", 8765, name="iPhone", via="iproxy")
        data = pc._read_device_file("MY-UDID")
        assert data["name"] == "iPhone"
        assert data["via"] == "iproxy"

    def test_unregister_existing(self, tmp_path, monkeypatch):
        monkeypatch.setattr(pc, "DEVICE_DIR", str(tmp_path / "devices"))
        pc.register_device("MY-UDID", "localhost", 9000)
        assert pc.unregister_device("MY-UDID") is True
        assert pc._read_device_file("MY-UDID") is None

    def test_unregister_missing_returns_false(self, tmp_path, monkeypatch):
        monkeypatch.setattr(pc, "DEVICE_DIR", str(tmp_path / "devices"))
        os.makedirs(str(tmp_path / "devices"), exist_ok=True)
        assert pc.unregister_device("NONEXISTENT") is False

    def test_read_missing_file_returns_none(self, tmp_path, monkeypatch):
        monkeypatch.setattr(pc, "DEVICE_DIR", str(tmp_path / "devices"))
        os.makedirs(str(tmp_path / "devices"), exist_ok=True)
        assert pc._read_device_file("GHOST") is None

    def test_read_corrupt_json_returns_none(self, tmp_path, monkeypatch):
        device_dir = str(tmp_path / "devices")
        os.makedirs(device_dir)
        monkeypatch.setattr(pc, "DEVICE_DIR", device_dir)
        path = os.path.join(device_dir, "BAD.device")
        with open(path, "w") as f:
            f.write("{not valid json")
        assert pc._read_device_file("BAD") is None


# ---------------------------------------------------------------------------
# discover_instance — PEPPER_CONNECT env var
# ---------------------------------------------------------------------------

class TestDiscoverInstanceEnvVar:
    def test_host_colon_port(self, monkeypatch):
        monkeypatch.setenv("PEPPER_CONNECT", "192.168.1.5:8765")
        host, port, udid = pc.discover_instance()
        assert host == "192.168.1.5"
        assert port == 8765
        assert udid == ""

    def test_port_only(self, monkeypatch):
        monkeypatch.setenv("PEPPER_CONNECT", "9876")
        host, port, udid = pc.discover_instance()
        assert host == "localhost"
        assert port == 9876

    def test_invalid_connect_raises(self, monkeypatch):
        monkeypatch.setenv("PEPPER_CONNECT", "notaport")
        with pytest.raises(RuntimeError, match="PEPPER_CONNECT"):
            pc.discover_instance()

    def test_empty_connect_falls_through(self, tmp_path, monkeypatch):
        monkeypatch.setenv("PEPPER_CONNECT", "")
        monkeypatch.setattr(pc, "PORT_DIR", str(tmp_path / "missing"))
        monkeypatch.setattr(pc, "DEVICE_DIR", str(tmp_path / "missing2"))
        monkeypatch.setattr(pc, "_bonjour_browse", lambda timeout=2.0: [])
        with pytest.raises(RuntimeError, match="No Pepper instances"):
            pc.discover_instance()

"""
Pepper common utilities — shared constants, config helpers, and port discovery.

Used by pepper-mcp, pepper-ctl, pepper-stream, and test-client.py.
"""

from __future__ import annotations

import json
import os
import re
import shutil
import socket
import subprocess
import sys

# ---------------------------------------------------------------------------
# Shared constants
# ---------------------------------------------------------------------------

PEPPER_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PORT_DIR = "/tmp/pepper-ports"
DEVICE_DIR = "/tmp/pepper-devices"
DEFAULT_HOST = "localhost"


def try_parse_json(value):
    """Try to parse a string as JSON for proper typing (bool, int, dict, list).
    Returns the parsed value on success, or the original string on failure."""
    if value is None:
        return None
    try:
        return json.loads(value)
    except (json.JSONDecodeError, TypeError):
        return value


def require_parse_json(value, field_name="value"):
    """Parse a string as JSON, raising ValueError with a descriptive message on failure."""
    try:
        return json.loads(value)
    except json.JSONDecodeError as e:
        raise ValueError(f"{field_name} must be valid JSON: {e}") from e


def require_tool(name: str, install_hint: str = "") -> str:
    """Check that an external CLI tool is on PATH. Returns the full path.

    Prints a clear error and exits if the tool is missing.
    """
    path = shutil.which(name)
    if path:
        return path
    msg = f"Error: '{name}' not found on PATH."
    if install_hint:
        msg += f" Install with: {install_hint}"
    print(msg, file=sys.stderr)
    sys.exit(1)


# ---------------------------------------------------------------------------
# .env loading
# ---------------------------------------------------------------------------


def load_env() -> dict[str, str]:
    """Load .env file from pepper repo root. Returns dict of key=value pairs."""
    env: dict[str, str] = {}
    env_path = os.path.join(PEPPER_DIR, ".env")
    if os.path.isfile(env_path):
        with open(env_path) as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, _, value = line.partition("=")
                env[key.strip()] = value.strip().strip("'\"")
    return env


# ---------------------------------------------------------------------------
# Build config
# ---------------------------------------------------------------------------


def get_config() -> dict[str, str]:
    """Get build config from .env + defaults."""
    env = load_env()
    return {
        "scheme": env.get("APP_SCHEME", ""),
        "bundle_id": env.get("APP_BUNDLE_ID", ""),
        "adapter_type": env.get("APP_ADAPTER_TYPE", "generic"),
        "xcodebuild_wrapper": os.path.join(PEPPER_DIR, "scripts", "xcodebuild.sh"),
        "dylib_path": env.get(
            "APP_DYLIB_PATH",
            os.path.join(PEPPER_DIR, "build", "Pepper.framework", "Pepper"),
        ),
        "device_xcodebuild_id": env.get("DEVICE_XCODEBUILD_ID", ""),
        "device_devicectl_uuid": env.get("DEVICE_DEVICECTL_UUID", ""),
    }


# ---------------------------------------------------------------------------
# Port liveness
# ---------------------------------------------------------------------------


def port_alive(port: int, host: str = "localhost", timeout: float = 1.0) -> bool:
    """Check if anything is listening on host:port via TCP connect."""
    try:
        s = socket.create_connection((host, port), timeout=timeout)
        s.close()
        return True
    except (TimeoutError, ConnectionRefusedError, OSError):
        return False


# ---------------------------------------------------------------------------
# Bonjour browse (fallback for on-device discovery)
# ---------------------------------------------------------------------------


def _bonjour_browse(timeout: float = 2.0) -> list[dict]:
    """Browse for _pepper._tcp. Bonjour services using dns-sd (macOS).

    Returns list of dicts with 'host', 'port', 'name' keys.
    Falls back to empty list on non-macOS or if dns-sd is unavailable.
    """
    if not shutil.which("dns-sd"):
        return []

    # Step 1: browse for service instances
    try:
        proc = subprocess.Popen(
            ["dns-sd", "-B", "_pepper._tcp.", "local."],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
        )
        try:
            browse_out, _ = proc.communicate(timeout=timeout)
        except subprocess.TimeoutExpired:
            proc.kill()
            browse_out, _ = proc.communicate()
    except OSError:
        return []

    # Parse: "  Add        2   1 local.  _pepper._tcp.  Pepper-com.example.app"
    names = []
    for line in browse_out.splitlines():
        m = re.search(r"\bAdd\b.+?_pepper\._tcp\.\s+(.+)$", line)
        if m:
            names.append(m.group(1).strip())

    if not names:
        return []

    # Step 2: resolve each service name to host:port
    results = []
    for name in names:
        try:
            proc = subprocess.Popen(
                ["dns-sd", "-L", name, "_pepper._tcp.", "local."],
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                text=True,
            )
            try:
                resolve_out, _ = proc.communicate(timeout=1.5)
            except subprocess.TimeoutExpired:
                proc.kill()
                resolve_out, _ = proc.communicate()
        except OSError:
            continue

        for line in resolve_out.splitlines():
            m = re.search(r"can be reached at (.+?):(\d+)", line)
            if m:
                raw_host = m.group(1).strip()
                port = int(m.group(2))
                # Resolve .local. hostname to IP (socket handles mDNS on macOS)
                try:
                    host = socket.gethostbyname(raw_host)
                except OSError:
                    host = raw_host
                results.append({"name": name, "host": host, "port": port})
                break

    return results


# ---------------------------------------------------------------------------
# Port discovery
# ---------------------------------------------------------------------------


def _resolve_port_file(simulator: str | None = None) -> tuple[str, int]:
    """Resolve a single (udid, port) from port files.

    If simulator is given, looks up that specific UDID.
    Otherwise auto-discovers from PORT_DIR (must have exactly one).
    Validates port liveness — cleans stale port files automatically.
    """
    if simulator:
        path = os.path.join(PORT_DIR, f"{simulator}.port")
        if os.path.exists(path):
            try:
                port = int(open(path).read().strip())
                if port_alive(port):
                    return simulator, port
                # Port is dead — clean up stale file
                try:
                    os.remove(path)
                except OSError:
                    pass
                raise RuntimeError(
                    f"Stale port file for {simulator} (app not responding on port {port}). "
                    f"Cleaned up. Re-deploy with `deploy`."
                )
            except ValueError:
                pass
        raise RuntimeError(f"No port file for simulator {simulator}")

    if os.path.isdir(PORT_DIR):
        # Filter to only live port files
        live_ports = []
        for f in sorted(os.listdir(PORT_DIR)):
            if not f.endswith(".port"):
                continue
            udid = f.replace(".port", "")
            port_path = os.path.join(PORT_DIR, f)
            try:
                port = int(open(port_path).read().strip())
            except (ValueError, OSError):
                continue
            if port_alive(port):
                live_ports.append((udid, port))
            else:
                # Stale — clean up
                try:
                    os.remove(port_path)
                except OSError:
                    pass

        if len(live_ports) == 1:
            return live_ports[0]
        elif len(live_ports) > 1:
            sims = [f"  {udid} → port {port}" for udid, port in live_ports]
            raise RuntimeError(
                f"Multiple simulators running ({len(live_ports)}). Pass simulator=UDID to pick one:\n" + "\n".join(sims)
            )
    raise RuntimeError("No Pepper instances found. Is the app running with dylib injection?")


def discover_port(simulator: str | None = None, fallback: int | None = None) -> int:
    """Auto-discover Pepper port from port files.

    If fallback is given, returns it instead of raising when no port is found
    (still raises on multiple simulators — caller must specify one).
    """
    try:
        _, port = _resolve_port_file(simulator)
        return port
    except RuntimeError as e:
        if fallback is not None and "Multiple" not in str(e):
            return fallback
        raise


def discover_simulator(simulator: str | None = None) -> tuple[str, int]:
    """Resolve simulator UDID and port. Returns (udid, port)."""
    return _resolve_port_file(simulator)


def list_simulators() -> list[dict]:
    """List all simulators with active Pepper connections (liveness-checked)."""
    sims = []
    if os.path.isdir(PORT_DIR):
        for f in sorted(os.listdir(PORT_DIR)):
            if f.endswith(".port"):
                udid = f.replace(".port", "")
                try:
                    port = int(open(os.path.join(PORT_DIR, f)).read().strip())
                    if port_alive(port):
                        sims.append({"udid": udid, "port": port})
                except (ValueError, OSError):
                    pass
    return sims


# ---------------------------------------------------------------------------
# Device discovery (physical devices via registered endpoints)
# ---------------------------------------------------------------------------


def _read_device_file(udid: str) -> dict | None:
    """Read a device registration file. Returns dict with host/port or None."""
    path = os.path.join(DEVICE_DIR, f"{udid}.device")
    try:
        with open(path) as f:
            data = json.load(f)
        if "host" in data and "port" in data:
            return data
    except (FileNotFoundError, json.JSONDecodeError, OSError, KeyError):
        pass
    return None


def register_device(udid: str, host: str, port: int, name: str = "", via: str = "") -> None:
    """Register a physical device endpoint for Pepper discovery.

    Creates a JSON file at /tmp/pepper-devices/{UDID}.device.
    Use after setting up connectivity (iproxy, WiFi, etc.).
    """
    os.makedirs(DEVICE_DIR, exist_ok=True)
    data = {"host": host, "port": port, "udid": udid}
    if name:
        data["name"] = name
    if via:
        data["via"] = via
    path = os.path.join(DEVICE_DIR, f"{udid}.device")
    with open(path, "w") as f:
        json.dump(data, f)


def unregister_device(udid: str) -> bool:
    """Remove a device registration. Returns True if file existed."""
    path = os.path.join(DEVICE_DIR, f"{udid}.device")
    try:
        os.remove(path)
        return True
    except FileNotFoundError:
        return False


def _resolve_device_file(device: str | None = None) -> tuple[str, int, str]:
    """Resolve a single (host, port, udid) from device files.

    If device UDID is given, looks up that specific device.
    Otherwise auto-discovers from DEVICE_DIR (must have exactly one live device).
    Validates liveness via TCP probe.
    """
    if device:
        data = _read_device_file(device)
        if data is None:
            raise RuntimeError(f"No device registered for UDID {device}")
        host, port = data["host"], data["port"]
        if port_alive(port, host=host):
            return host, port, device
        raise RuntimeError(
            f"Device {device} registered at {host}:{port} but not responding. "
            f"Check connectivity (iproxy / WiFi) and re-register."
        )

    if not os.path.isdir(DEVICE_DIR):
        raise RuntimeError("No devices registered")

    live_devices: list[tuple[str, int, str]] = []
    for f in sorted(os.listdir(DEVICE_DIR)):
        if not f.endswith(".device"):
            continue
        udid = f.removesuffix(".device")
        data = _read_device_file(udid)
        if data is None:
            continue
        host, port = data["host"], data["port"]
        if port_alive(port, host=host):
            live_devices.append((host, port, udid))
        else:
            # Stale device — remove
            try:
                os.remove(os.path.join(DEVICE_DIR, f))
            except OSError:
                pass

    if len(live_devices) == 1:
        return live_devices[0]
    elif len(live_devices) > 1:
        lines = [f"  {udid} → {host}:{port}" for host, port, udid in live_devices]
        raise RuntimeError(
            f"Multiple devices responding ({len(live_devices)}). Pass device=UDID to pick one:\n" + "\n".join(lines)
        )
    raise RuntimeError("No devices registered")


def list_devices() -> list[dict]:
    """List all registered devices with liveness status."""
    devices = []
    if os.path.isdir(DEVICE_DIR):
        for f in sorted(os.listdir(DEVICE_DIR)):
            if f.endswith(".device"):
                udid = f.removesuffix(".device")
                data = _read_device_file(udid)
                if data:
                    data["alive"] = port_alive(data["port"], host=data["host"])
                    devices.append(data)
    return devices


# ---------------------------------------------------------------------------
# Unified instance discovery (simulators + devices)
# ---------------------------------------------------------------------------


def discover_instance(identifier: str | None = None) -> tuple[str, int, str]:
    """Discover a Pepper instance — simulator or device. Returns (host, port, udid).

    Resolution order:
    1. PEPPER_CONNECT env var (explicit host:port — always wins).
    2. If identifier given: check simulator port files, then device files.
    3. If not given: collect all live sims and devices; require exactly one.
    4. Bonjour browse fallback (when no port/device files are present).
    """
    # Fast path: explicit env var override
    connect = os.environ.get("PEPPER_CONNECT", "").strip()
    if connect:
        if ":" in connect:
            host, _, portstr = connect.rpartition(":")
        else:
            host, portstr = "localhost", connect
        try:
            port = int(portstr)
        except ValueError as e:
            raise RuntimeError(
                f"PEPPER_CONNECT={connect!r} is not valid. "
                f"Expected host:port or port (e.g. 192.168.1.100:8765 or 8765)."
            ) from e
        return host or "localhost", port, ""

    if identifier:
        # Try simulator first
        sim_path = os.path.join(PORT_DIR, f"{identifier}.port")
        if os.path.exists(sim_path):
            try:
                port = int(open(sim_path).read().strip())
                if port_alive(port):
                    return "localhost", port, identifier
            except (ValueError, OSError):
                pass

        # Try device
        device_data = _read_device_file(identifier)
        if device_data:
            host, port = device_data["host"], device_data["port"]
            if port_alive(port, host=host):
                return host, port, identifier
            raise RuntimeError(f"Instance {identifier} registered at {host}:{port} but not responding.")

        raise RuntimeError(
            f"No Pepper instance found for {identifier}. Check simulator port files and device registrations."
        )

    # Auto-discover: collect all live instances
    instances: list[tuple[str, int, str, str]] = []  # (host, port, udid, kind)

    # Simulators
    if os.path.isdir(PORT_DIR):
        for f in sorted(os.listdir(PORT_DIR)):
            if not f.endswith(".port"):
                continue
            udid = f.removesuffix(".port")
            try:
                port = int(open(os.path.join(PORT_DIR, f)).read().strip())
            except (ValueError, OSError):
                continue
            if port_alive(port):
                instances.append(("localhost", port, udid, "simulator"))

    # Devices
    if os.path.isdir(DEVICE_DIR):
        for f in sorted(os.listdir(DEVICE_DIR)):
            if not f.endswith(".device"):
                continue
            udid = f.removesuffix(".device")
            data = _read_device_file(udid)
            if data and port_alive(data["port"], host=data["host"]):
                instances.append((data["host"], data["port"], udid, "device"))

    if len(instances) == 1:
        host, port, udid, _ = instances[0]
        return host, port, udid
    elif len(instances) > 1:
        lines = []
        for host, port, udid, kind in instances:
            addr = f"{host}:{port}" if kind == "device" else f"localhost:{port}"
            lines.append(f"  {udid} → {addr} ({kind})")
        raise RuntimeError(
            f"Multiple Pepper instances running ({len(instances)}). "
            f"Specify simulator=UDID or device=UDID:\n" + "\n".join(lines)
        )

    # Bonjour browse fallback — useful for on-device discovery without iproxy/WiFi setup
    bonjour = _bonjour_browse()
    live_bonjour = [s for s in bonjour if port_alive(s["port"], host=s["host"])]
    if len(live_bonjour) == 1:
        s = live_bonjour[0]
        return s["host"], s["port"], ""
    elif len(live_bonjour) > 1:
        lines = [f"  {s['name']} → {s['host']}:{s['port']}" for s in live_bonjour]
        raise RuntimeError(
            f"Multiple Pepper services found via Bonjour ({len(live_bonjour)}). "
            f"Set PEPPER_CONNECT=host:port or pass identifier:\n" + "\n".join(lines)
        )

    raise RuntimeError(
        "No Pepper instances found. Is the app running with dylib injection, "
        "or is a device registered? Set PEPPER_CONNECT=host:port to connect directly."
    )


def list_instances() -> list[dict]:
    """List all live Pepper instances (simulators + devices)."""
    instances = []
    for sim in list_simulators():
        sim["kind"] = "simulator"
        sim["host"] = "localhost"
        instances.append(sim)
    for dev in list_devices():
        if dev.get("alive"):
            dev["kind"] = "device"
            instances.append(dev)
    return instances

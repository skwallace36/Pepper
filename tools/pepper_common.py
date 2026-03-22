"""
Pepper common utilities — shared constants, config helpers, and port discovery.

Used by pepper-mcp, pepper-ctl, pepper-stream, and test-client.py.
"""

import os
import socket
from typing import Optional


# ---------------------------------------------------------------------------
# Shared constants
# ---------------------------------------------------------------------------

PEPPER_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PORT_DIR = "/tmp/pepper-ports"
DEFAULT_HOST = "localhost"


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

def port_alive(port: int, timeout: float = 1.0) -> bool:
    """Check if anything is listening on localhost:port via TCP connect."""
    try:
        s = socket.create_connection(("localhost", port), timeout=timeout)
        s.close()
        return True
    except (ConnectionRefusedError, OSError, socket.timeout):
        return False


# ---------------------------------------------------------------------------
# Port discovery
# ---------------------------------------------------------------------------

def _resolve_port_file(simulator: Optional[str] = None) -> tuple[str, int]:
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
                f"Multiple simulators running ({len(live_ports)}). "
                f"Pass simulator=UDID to pick one:\n" + "\n".join(sims)
            )
    raise RuntimeError("No Pepper instances found. Is the app running with dylib injection?")


def discover_port(simulator: Optional[str] = None, fallback: Optional[int] = None) -> int:
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


def discover_simulator(simulator: Optional[str] = None) -> tuple[str, int]:
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

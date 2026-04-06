"""pepper test lifecycle -- headless simulator management for test runs.

Handles: find/create sim → boot → build dylib → build app → install →
inject → wait for server → (tests run) → teardown.

Used by test_runner.py when --project is provided.
"""

from __future__ import annotations

import hashlib
import json
import os
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path

from .pepper_websocket import CrashError, make_command, send_command_sync

DEFAULT_PORT_BASE = 8770
PORT_RANGE = 100


@dataclass
class SimContext:
    """Running simulator context for test execution."""
    udid: str
    port: int
    host: str = "localhost"
    created: bool = False  # True if we created it (cleanup will delete)
    app_pid: int | None = None


def _log(msg: str) -> None:
    print(f"  {msg}", file=sys.stderr)


def _step(msg: str) -> None:
    print(f"\n▸ {msg}", file=sys.stderr)


def _port_for_udid(udid: str) -> int:
    """Deterministic port from UDID, matching Makefile convention."""
    h = int(hashlib.md5(udid.encode()).hexdigest()[:4], 16)
    return DEFAULT_PORT_BASE + (h % PORT_RANGE)


def _run(cmd: list[str], check: bool = True, capture: bool = True,
         timeout: int = 300) -> subprocess.CompletedProcess:
    """Run a subprocess, optionally checking return code."""
    return subprocess.run(
        cmd, capture_output=capture, text=True,
        timeout=timeout, check=check,
    )


# ---------------------------------------------------------------------------
# Simulator management
# ---------------------------------------------------------------------------

def find_or_create_simulator(simulator: str | None = None,
                             device: str = "iPhone 16") -> SimContext:
    """Find an existing booted sim or create one."""
    if simulator:
        _step(f"Using simulator: {simulator}")
        udid = simulator
        # Boot if not already booted
        _boot_simulator(udid)
        return SimContext(udid=udid, port=_port_for_udid(udid), created=False)

    # Check for already-booted sims
    result = _run(["xcrun", "simctl", "list", "devices", "booted", "-j"])
    data = json.loads(result.stdout)
    booted = [
        d["udid"] for runtime in data.get("devices", {}).values()
        for d in runtime if d.get("state") == "Booted"
    ]

    if booted:
        udid = booted[0]
        _step(f"Using booted simulator: {udid}")
        return SimContext(udid=udid, port=_port_for_udid(udid), created=False)

    # Create a new one
    _step(f"Creating simulator ({device})")
    runtime = _detect_runtime()
    device_type = f"com.apple.CoreSimulator.SimDeviceType.{device.replace(' ', '-')}"
    runtime_id = f"com.apple.CoreSimulator.SimRuntime.{runtime}"

    result = _run(["xcrun", "simctl", "create", "PepperTest", device_type, runtime_id])
    udid = result.stdout.strip()
    _log(f"Created: {udid}")

    _boot_simulator(udid)
    return SimContext(udid=udid, port=_port_for_udid(udid), created=True)


def _detect_runtime() -> str:
    """Auto-detect the latest iOS runtime."""
    result = _run(["xcrun", "simctl", "list", "runtimes", "-j"])
    runtimes = json.loads(result.stdout).get("runtimes", [])
    ios = [r for r in runtimes if r.get("platform") == "iOS" and r.get("isAvailable")]
    if ios:
        ios.sort(key=lambda r: r.get("version", "0"), reverse=True)
        return ios[0]["identifier"].split(".")[-1]
    return "iOS-18-2"


def _boot_simulator(udid: str) -> None:
    """Boot simulator if not already booted."""
    _run(["xcrun", "simctl", "boot", udid], check=False)
    _run(["xcrun", "simctl", "bootstatus", udid, "-b"], check=False, timeout=60)
    _log("Simulator booted")


# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------

def build_dylib(project_dir: str) -> str:
    """Build the Pepper dylib. Returns path to framework binary."""
    _step("Building Pepper dylib")
    _run(["make", "-C", project_dir, "build"], capture=False, timeout=120)
    dylib_path = os.path.join(project_dir, "build", "Pepper.framework", "Pepper")
    if not os.path.exists(dylib_path):
        print("Error: Pepper.framework not found after build", file=sys.stderr)
        sys.exit(2)
    _log(f"Built: {dylib_path}")
    return dylib_path


def build_and_install_app(project: str, scheme: str | None,
                          sim_udid: str) -> str:
    """Build an Xcode project/workspace and install on simulator.

    Returns the bundle ID.
    """
    _step(f"Building app: {os.path.basename(project)}")
    project_path = Path(project).resolve()

    if project_path.suffix == ".xcworkspace":
        build_flag = "-workspace"
    elif project_path.suffix == ".xcodeproj":
        build_flag = "-project"
    else:
        print(f"Error: {project} must be .xcworkspace or .xcodeproj", file=sys.stderr)
        sys.exit(2)

    # Determine scheme
    if not scheme:
        scheme = project_path.stem

    # Build
    _run([
        "xcodebuild", build_flag, str(project_path),
        "-scheme", scheme,
        "-sdk", "iphonesimulator",
        "-destination", f"id={sim_udid}",
        "-configuration", "Debug",
        "build", "-quiet",
    ], capture=False, timeout=300)

    # Find the built .app
    derived = Path.home() / "Library/Developer/Xcode/DerivedData"
    apps = list(derived.glob(f"{scheme}-*/Build/Products/Debug-iphonesimulator/{scheme}.app"))
    if not apps:
        # Try broader search
        apps = list(derived.glob(f"**/Debug-iphonesimulator/{scheme}.app"))
    if not apps:
        print(f"Error: Built .app not found for scheme {scheme}", file=sys.stderr)
        sys.exit(2)

    app_path = str(apps[0])

    # Extract bundle ID
    info_plist = os.path.join(app_path, "Info.plist")
    result = _run(["plutil", "-extract", "CFBundleIdentifier", "raw", info_plist])
    bundle_id = result.stdout.strip()

    # Install
    _step("Installing app")
    _run(["xcrun", "simctl", "install", sim_udid, app_path])
    _log(f"Installed {bundle_id}")

    return bundle_id


# ---------------------------------------------------------------------------
# Launch with injection
# ---------------------------------------------------------------------------

def launch_with_pepper(sim: SimContext, bundle_id: str, dylib_path: str,
                       adapter: str = "generic") -> None:
    """Launch app with Pepper dylib injected."""
    _step("Launching with Pepper injection")

    # Terminate any existing instance
    _run(["xcrun", "simctl", "terminate", sim.udid, bundle_id], check=False)
    time.sleep(0.5)

    # Grant common privacy permissions
    for perm in ["photos", "photos-add", "camera", "microphone", "contacts",
                 "calendar", "location-always"]:
        _run(["xcrun", "simctl", "privacy", sim.udid, "grant", perm, bundle_id],
             check=False)

    # Clean stale port/session files
    port_file = f"/tmp/pepper-ports/{sim.udid}.port"
    session_file = f"/tmp/pepper-sessions/{sim.udid}.session"
    for f in [port_file, session_file]:
        try:
            os.remove(f)
        except FileNotFoundError:
            pass

    # Launch with DYLD injection
    env = os.environ.copy()
    env["SIMCTL_CHILD_DYLD_INSERT_LIBRARIES"] = dylib_path
    env["SIMCTL_CHILD_PEPPER_PORT"] = str(sim.port)
    env["SIMCTL_CHILD_PEPPER_SIM_UDID"] = sim.udid
    env["SIMCTL_CHILD_PEPPER_ADAPTER"] = adapter
    env["SIMCTL_CHILD_PEPPER_SKIP_PERMISSIONS"] = "1"

    result = subprocess.run(
        ["xcrun", "simctl", "launch", sim.udid, bundle_id],
        env=env, capture_output=True, text=True,
    )

    if result.returncode != 0:
        print(f"Error launching app: {result.stderr}", file=sys.stderr)
        sys.exit(2)

    # Parse PID from output (format: "com.example.app: 12345")
    output = result.stdout.strip()
    if ":" in output:
        try:
            sim.app_pid = int(output.split(":")[-1].strip())
        except ValueError:
            pass

    _log(f"Launched on port {sim.port} (PID: {sim.app_pid})")


# ---------------------------------------------------------------------------
# Wait for server
# ---------------------------------------------------------------------------

def wait_for_server(host: str, port: int, timeout: int = 30) -> bool:
    """Wait for Pepper WebSocket server to respond to ping."""
    _step(f"Waiting for Pepper server (timeout: {timeout}s)")
    deadline = time.monotonic() + timeout
    attempt = 0

    while time.monotonic() < deadline:
        attempt += 1
        try:
            msg = make_command("ping")
            resp = send_command_sync(host, port, msg, timeout=3)
            if resp.get("status") == "ok":
                _log(f"Server ready (attempt {attempt})")
                return True
        except (ConnectionRefusedError, ConnectionResetError,
                TimeoutError, OSError, CrashError):
            pass
        time.sleep(1)

    print(f"Error: Server not reachable after {timeout}s ({attempt} attempts)",
          file=sys.stderr)
    return False


# ---------------------------------------------------------------------------
# Teardown
# ---------------------------------------------------------------------------

def teardown(sim: SimContext, bundle_id: str | None = None) -> None:
    """Clean up after test run."""
    _step("Teardown")

    if bundle_id:
        _run(["xcrun", "simctl", "terminate", sim.udid, bundle_id], check=False)
        _log("App terminated")

    # Clean port/session files
    for pattern in [f"/tmp/pepper-ports/{sim.udid}.port",
                    f"/tmp/pepper-sessions/{sim.udid}.session"]:
        try:
            os.remove(pattern)
        except FileNotFoundError:
            pass

    if sim.created:
        _run(["xcrun", "simctl", "shutdown", sim.udid], check=False)
        _run(["xcrun", "simctl", "delete", sim.udid], check=False)
        _log(f"Simulator {sim.udid} deleted")
    else:
        _log(f"Simulator {sim.udid} kept (pre-existing)")


# ---------------------------------------------------------------------------
# Full lifecycle
# ---------------------------------------------------------------------------

def run_lifecycle(project: str, scheme: str | None = None,
                  simulator: str | None = None,
                  server_timeout: int = 30) -> tuple[SimContext, str]:
    """Run the full lifecycle: sim → build → inject → wait.

    Returns (sim_context, bundle_id) ready for test execution.
    """
    # Find pepper project root (where Makefile lives)
    pepper_root = _find_pepper_root()

    # Simulator
    sim = find_or_create_simulator(simulator)

    # Build dylib
    dylib_path = build_dylib(pepper_root)

    # Build and install app
    bundle_id = build_and_install_app(project, scheme, sim.udid)

    # Launch with injection
    launch_with_pepper(sim, bundle_id, dylib_path)

    # Wait for server
    if not wait_for_server(sim.host, sim.port, server_timeout):
        teardown(sim, bundle_id)
        sys.exit(2)

    return sim, bundle_id


def _find_pepper_root() -> str:
    """Find the Pepper project root (directory containing Makefile and dylib/)."""
    # Check common locations
    candidates = [
        os.environ.get("PEPPER_ROOT", ""),
        os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    ]
    for path in candidates:
        if path and os.path.isfile(os.path.join(path, "Makefile")) and \
           os.path.isdir(os.path.join(path, "dylib")):
            return path

    print("Error: Cannot find Pepper project root. Set PEPPER_ROOT env var.",
          file=sys.stderr)
    sys.exit(2)

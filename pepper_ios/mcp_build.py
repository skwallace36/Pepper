"""Build, deploy, and iterate helpers for Pepper MCP.

Simulator resolution, xcodebuild invocation, app deployment with dylib injection,
and physical device build/install/launch.
"""

from __future__ import annotations

import asyncio
import json
import os
import shutil
import subprocess
import tempfile
from collections.abc import Callable

from . import pepper_sessions
from .pepper_common import PORT_DIR, get_config
from .pepper_format import format_look

# Type alias for the send_command callable expected by deploy_app.
# Signature: async (port, cmd, params=None, timeout=10) -> dict
SendFn = Callable[..., "asyncio.Future[dict]"]

# Per-simulator build state: maps sim UDID -> workspace path used for last build.
# This way multiple Claude sessions building for different sims don't clobber each other.
_sim_build_state: dict[str, str] = {}


def _extract_build_errors(output: str, label: str = "BUILD FAILED") -> str:
    """Extract error details from xcodebuild output.

    For package resolution failures, includes the full block of detail lines
    that follow the error (they don't contain 'error:' themselves).
    For other failures, deduplicates lines containing 'error:'.
    """
    lines = output.split("\n")

    # Check for package resolution failure — grab the error line and all
    # subsequent non-blank lines that form the dependency detail block.
    for i, line in enumerate(lines):
        if "could not resolve package dependencies" in line.lower():
            block = [line.strip()]
            for j in range(i + 1, len(lines)):
                stripped = lines[j].strip()
                if not stripped:
                    break
                block.append(stripped)
            return f"{label}\n" + "\n".join(block[:40])

    # General case: deduplicate error: lines
    error_lines: list[str] = []
    seen: set[str] = set()
    for line in lines:
        if "error:" in line.lower():
            normalized = line.strip()
            if normalized not in seen:
                seen.add(normalized)
                error_lines.append(normalized)
    if error_lines:
        return f"{label}\n" + "\n".join(error_lines[:20])

    # Last resort: tail of output
    return f"{label}\n" + "\n".join(line.strip() for line in lines[-20:])

# Session-sticky simulator: once this MCP server process resolves a simulator,
# it remembers and reuses it for all subsequent calls. Prevents accidentally
# grabbing another Claude session's sim when auto-resolving.
_session_simulator: str | None = None


# ---------------------------------------------------------------------------
# Simulator helpers
# ---------------------------------------------------------------------------


def _clean_stale_port(simulator: str):
    """Remove stale port file before (re)launch so we wait for the fresh one."""
    port_file = os.path.join(PORT_DIR, f"{simulator}.port")
    if os.path.exists(port_file):
        try:
            os.remove(port_file)
        except OSError:
            pass


def is_sim_booted(udid: str) -> bool:
    """Check if a specific simulator is booted."""
    result = subprocess.run(["xcrun", "simctl", "list", "devices", "booted", "-j"], capture_output=True, text=True)
    try:
        data = json.loads(result.stdout)
        for _runtime, devices in data.get("devices", {}).items():
            for d in devices:
                if d["udid"] == udid and d.get("state") == "Booted":
                    return True
    except (json.JSONDecodeError, KeyError):
        pass
    return False


def boot_simulator(udid: str):
    """Boot a simulator via Simulator.app (not simctl boot — that causes black screens)."""
    # open -a Simulator connects to the Simulator UI properly
    subprocess.run(["open", "-a", "Simulator", "--args", "-CurrentDeviceUDID", udid], capture_output=True, text=True)
    try:
        subprocess.run(["xcrun", "simctl", "bootstatus", udid, "-b"], capture_output=True, text=True, timeout=120)
    except subprocess.TimeoutExpired:
        pass  # Proceed anyway — bootstatus can hang even when sim is ready


def find_available_iphone() -> str | None:
    """Find the best available iPhone simulator to boot. Returns UDID or None."""
    result = subprocess.run(["xcrun", "simctl", "list", "devices", "available", "-j"], capture_output=True, text=True)
    try:
        data = json.loads(result.stdout)
        # Collect iPhones from iOS runtimes, prefer newest runtime
        iphones = []
        for runtime in sorted(data.get("devices", {}).keys(), reverse=True):
            if "iOS" not in runtime and "iphone" not in runtime.lower():
                continue
            for d in data["devices"][runtime]:
                if d.get("isAvailable") and "iPhone" in d.get("name", ""):
                    iphones.append(d)
        # Prefer Pro models, then newest
        for keyword in ["Pro Max", "Pro", "iPhone"]:
            for d in iphones:
                if keyword in d["name"]:
                    return d["udid"]
        if iphones:
            return iphones[0]["udid"]
    except (json.JSONDecodeError, KeyError):
        pass
    return None


def resolve_simulator(simulator: str | None = None) -> str:
    """Resolve simulator UDID with session awareness.

    Resolution order:
    1. Explicit param (always wins)
    2. Session affinity (reuse previously resolved sim for this process)
    3. Our existing session claim (from pepper_sessions)
    4. Unclaimed sim with Pepper running
    5. Unclaimed booted sim
    6. Boot an existing unbooted iPhone sim
    7. Error if at cap

    Updates heartbeat on every call. Sticky for this MCP server process.
    """
    global _session_simulator

    # Explicit param always wins
    if simulator:
        _session_simulator = simulator
        pepper_sessions.heartbeat(simulator)
        return simulator

    # Session affinity: reuse the sim from a previous call in this session
    if _session_simulator:
        pepper_sessions.heartbeat(_session_simulator)
        return _session_simulator

    # Check if we already own a session from a previous process lifecycle
    owned = pepper_sessions.my_session()
    if owned:
        _session_simulator = owned
        pepper_sessions.heartbeat(owned)
        return owned

    # Clean up stale sessions before searching
    pepper_sessions.cleanup_stale()

    # Find an available simulator (reuse-first, capped)
    # This covers: unclaimed Pepper sims, unclaimed booted sims, unbooted sims
    try:
        udid = pepper_sessions.find_available_simulator()
    except RuntimeError:
        raise  # Propagate cap errors and "no sims" errors

    # If the sim needs booting, boot it
    if not is_sim_booted(udid):
        boot_simulator(udid)

    _session_simulator = udid
    return udid


# ---------------------------------------------------------------------------
# Prebuilt artifact fixup (Xcode 26.3+)
# ---------------------------------------------------------------------------


def _fix_prebuilt_artifacts(derived_data: str) -> None:
    """Copy prebuilt package artifacts from standard DerivedData if missing.

    Xcode 26.3+ may not extract prebuilt modules (e.g. swift-syntax) into
    non-standard DerivedData paths set via -derivedDataPath. When empty
    artifact bundles are detected, this copies populated versions from
    ~/Library/Developer/Xcode/DerivedData/.
    """
    artifacts_dir = os.path.join(derived_data, "SourcePackages", "artifacts")
    if not os.path.isdir(artifacts_dir):
        return

    # Find artifact packages with empty directories (resolved but not extracted)
    empty_pkgs = []
    for name in os.listdir(artifacts_dir):
        pkg_path = os.path.join(artifacts_dir, name)
        if os.path.isdir(pkg_path) and not any(f for _, _, files in os.walk(pkg_path) for f in files):
            empty_pkgs.append(name)

    if not empty_pkgs:
        return

    # Search standard DerivedData for populated copies
    std_dd = os.path.expanduser("~/Library/Developer/Xcode/DerivedData")
    if not os.path.isdir(std_dd):
        return

    for entry in os.listdir(std_dd):
        std_artifacts = os.path.join(std_dd, entry, "SourcePackages", "artifacts")
        if not os.path.isdir(std_artifacts):
            continue
        for pkg_name in list(empty_pkgs):
            src = os.path.join(std_artifacts, pkg_name)
            if not os.path.isdir(src):
                continue
            if any(f for _, _, files in os.walk(src) for f in files):
                dst = os.path.join(artifacts_dir, pkg_name)
                shutil.rmtree(dst)
                shutil.copytree(src, dst)
                empty_pkgs.remove(pkg_name)
        if not empty_pkgs:
            break


# ---------------------------------------------------------------------------
# Simulator build & deploy
# ---------------------------------------------------------------------------


async def build_app(
    workspace: str | None = None, scheme: str | None = None, simulator: str | None = None
) -> tuple[bool, str]:
    """Build the app. Returns (success, message). Message includes errors on failure."""
    cfg = get_config()
    ws = workspace
    sch = scheme or cfg["scheme"]
    wrapper = cfg["xcodebuild_wrapper"]

    if not ws:
        return False, "workspace is required — pass the absolute path to the .xcworkspace"
    if not sch:
        return False, "No scheme configured. Set APP_SCHEME in pepper/.env"
    if not os.path.exists(ws):
        return False, f"Workspace not found: {ws}"

    # Resolve simulator for -destination (also auto-boots if needed)
    try:
        sim_udid = resolve_simulator(simulator)
    except RuntimeError as e:
        return False, str(e)

    # Ensure simulator is booted before building (xcodebuild needs a booted destination)
    if not is_sim_booted(sim_udid):
        boot_simulator(sim_udid)

    cmd = [
        wrapper,
        "-workspace",
        ws,
        "-scheme",
        sch,
        "-configuration",
        "Debug",
        "-destination",
        f"platform=iOS Simulator,id={sim_udid}",
        "-skipPackagePluginValidation",
        "-skipMacroValidation",
        "DEBUG_INFORMATION_FORMAT=dwarf-with-dsym",
        "build",
    ]

    # If wrapper doesn't exist, fall back to raw xcodebuild with manual DerivedData isolation
    custom_derived_data = None
    if not os.path.exists(wrapper):
        cmd[0] = "xcodebuild"
        # Add worktree-aware DerivedData path manually
        ws_dir = os.path.dirname(os.path.abspath(ws))
        worktree_name = os.path.basename(ws_dir)
        custom_derived_data = f"/tmp/DerivedData-{worktree_name}"
        cmd.extend(["-derivedDataPath", custom_derived_data])

    proc = await asyncio.create_subprocess_exec(
        *cmd,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.STDOUT,
    )
    stdout, _ = await proc.communicate()
    output = stdout.decode("utf-8", errors="replace")

    if proc.returncode == 0:
        _sim_build_state[sim_udid] = ws  # remember workspace per sim for deploy
        if custom_derived_data:
            _fix_prebuilt_artifacts(custom_derived_data)
        lines = output.strip().split("\n")
        summary = "\n".join(lines[-3:]) if len(lines) > 3 else output.strip()
        return True, f"BUILD SUCCEEDED\n{summary}"
    else:
        return False, _extract_build_errors(output, "BUILD FAILED")


async def deploy_app(
    simulator: str,
    send_fn: SendFn,
    bundle_id: str | None = None,
    dylib_path: str | None = None,
    install_path: str | None = None,
    workspace: str | None = None,
    skip_privacy: bool = False,
) -> str:
    """Deploy (terminate + install + launch with Pepper). Returns status message + screen."""
    cfg = get_config()
    bid = bundle_id or cfg["bundle_id"]
    dylib = dylib_path or cfg["dylib_path"]

    if not bid:
        return "No bundle ID configured. Set APP_BUNDLE_ID in pepper/.env"
    if not os.path.exists(dylib):
        return f"Pepper dylib not found at {dylib}. Run `make build` in pepper dir."

    # Session guard: refuse to deploy if another session owns this simulator
    session = pepper_sessions.is_claimed(simulator)
    if session and session.get("pid") != os.getpid():
        label = session.get("label", "")
        label_str = f" ({label})" if label else ""
        return (
            f"Simulator {simulator} is in use by another Pepper session "
            f"(PID {session['pid']}{label_str}, claimed at {session.get('claimed_at', '?')}). "
            f"Use a different simulator or wait for that session to finish.\n"
            f"Tip: use `simulator action=list` to see all available simulators."
        )

    # Ensure simulator is booted
    if not is_sim_booted(simulator):
        boot_simulator(simulator)

    # Clean stale port file so we wait for the fresh Pepper instance
    _clean_stale_port(simulator)

    # Terminate existing app
    subprocess.run(["xcrun", "simctl", "terminate", simulator, bid], capture_output=True, text=True)

    # Auto-find latest built app if no install_path given.
    # Use the workspace from the last build targeting this sim (handles worktrees correctly).
    if not install_path:
        ws = workspace or _sim_build_state.get(simulator)
        install_path = find_built_app(workspace=ws)

    # Install if we have an app path
    if install_path and os.path.exists(install_path):
        result = subprocess.run(["xcrun", "simctl", "install", simulator, install_path], capture_output=True, text=True)
        if result.returncode != 0:
            return f"Install failed: {result.stderr.strip()}"

    # Grant ALL privacy permissions at once (opt-out with skip_privacy=True).
    # "grant all" covers every service simctl supports in one call.
    if not skip_privacy:
        subprocess.run(["xcrun", "simctl", "privacy", simulator, "grant", "all", bid], capture_output=True, text=True)

    # Enable VoiceOver accessibility flag so SwiftUI apps populate labels.
    # Many apps (Ice Cubes, etc.) only compute accessibilityLabel when VoiceOver is on.
    subprocess.run(
        [
            "xcrun",
            "simctl",
            "spawn",
            simulator,
            "defaults",
            "write",
            "com.apple.Accessibility",
            "VoiceOverTouchEnabled",
            "-bool",
            "true",
        ],
        capture_output=True,
        text=True,
    )

    # Launch with injection + adapter env vars
    env = os.environ.copy()
    env["SIMCTL_CHILD_DYLD_INSERT_LIBRARIES"] = dylib
    env["SIMCTL_CHILD_PEPPER_ADAPTER"] = cfg.get("adapter_type", "generic")
    env["SIMCTL_CHILD_PEPPER_SIM_UDID"] = simulator
    # Skip authorization swizzles when we already granted permissions via simctl.
    # The swizzles intentionally trigger dialogs for testing — but deploy already
    # grants permissions, so the dialogs are redundant and block agents/users.
    if not skip_privacy:
        env["SIMCTL_CHILD_PEPPER_SKIP_PERMISSIONS"] = "1"
    result = subprocess.run(["xcrun", "simctl", "launch", simulator, bid], capture_output=True, text=True, env=env)

    if result.returncode != 0:
        stderr = result.stderr.strip()
        if "not booted" in stderr.lower():
            return f"Launch failed: simulator {simulator} is not booted. Try again or boot it manually."
        return f"Launch failed: {stderr}"

    pid = result.stdout.strip().split(":")[-1].strip() if ":" in result.stdout else result.stdout.strip()

    # Wait for Pepper to connect (10s timeout — cold launches need more time)
    port_file = os.path.join(PORT_DIR, f"{simulator}.port")
    for _attempt in range(20):
        await asyncio.sleep(0.5)
        if os.path.exists(port_file):
            try:
                port = int(open(port_file).read().strip())
                resp = await send_fn(port, "ping", timeout=2)
                if resp.get("status") == "ok":
                    await asyncio.sleep(1)  # let UI settle
                    look_resp = await send_fn(port, "look", {}, timeout=30)
                    screen_summary = (
                        format_look(look_resp) if look_resp.get("status") == "ok" else "(look not ready yet)"
                    )
                    # Reset monitor state so stale data from previous session doesn't leak
                    from .mcp_server import reset_monitor_state
                    reset_monitor_state()
                    # Claim this simulator for our session
                    pepper_sessions.claim_simulator(simulator, bundle_id=bid, port=port)
                    return f"Deployed to {simulator} (PID {pid}, port {port}). Pepper is connected.\n--- Screen ---\n{screen_summary}"
            except (TimeoutError, OSError, ValueError):
                pass

    return f"App launched (PID {pid}) but Pepper didn't respond within 10s. Check dylib injection. Port file exists: {os.path.exists(port_file)}"


def find_built_app(workspace: str | None = None, platform: str = "iphonesimulator") -> str | None:
    """Find the most recently built .app in DerivedData based on workspace path.
    platform: 'iphonesimulator' or 'iphoneos'"""
    ws = workspace
    if not ws:
        return None

    ws_dir = os.path.dirname(os.path.abspath(ws))
    worktree_name = os.path.basename(ws_dir)
    derived_data = f"/tmp/DerivedData-{worktree_name}"
    app_dir = os.path.join(derived_data, "Build", "Products", f"Debug-{platform}")

    if os.path.isdir(app_dir):
        apps = []
        for item in os.listdir(app_dir):
            if item.endswith(".app"):
                full_path = os.path.join(app_dir, item)
                try:
                    mtime = os.path.getmtime(full_path)
                    apps.append((mtime, full_path))
                except OSError:
                    pass
        if apps:
            # Return most recently modified .app
            apps.sort(reverse=True)
            return apps[0][1]
    return None


# ---------------------------------------------------------------------------
# Physical device build & deploy
# ---------------------------------------------------------------------------


async def verify_device_connected(devicectl_uuid: str) -> tuple[bool, str]:
    """Check if a physical device is connected via devicectl. Returns (connected, message)."""
    tmp_path = None
    try:
        fd, tmp_path = tempfile.mkstemp(suffix=".json")
        os.close(fd)
        result = subprocess.run(
            ["xcrun", "devicectl", "list", "devices", "-j", tmp_path], capture_output=True, text=True, timeout=15
        )
        if result.returncode != 0:
            return False, f"devicectl list failed: {result.stderr.strip()}"
        with open(tmp_path) as f:
            data = json.load(f)
        devices = data.get("result", {}).get("devices", [])
        for dev in devices:
            if dev.get("identifier") == devicectl_uuid:
                state = dev.get("connectionProperties", {}).get("transportType", "unknown")
                name = dev.get("deviceProperties", {}).get("name", "unknown")
                return True, f"Connected: {name} ({state})"
        return False, f"Device {devicectl_uuid} not found. Is it connected?"
    except (json.JSONDecodeError, KeyError) as e:
        return False, f"Failed to parse devicectl output: {e}"
    finally:
        if tmp_path and os.path.exists(tmp_path):
            os.unlink(tmp_path)


async def build_app_device(
    workspace: str | None = None, scheme: str | None = None, xcodebuild_id: str | None = None
) -> tuple[bool, str]:
    """Build the app for a physical device. Returns (success, message)."""
    cfg = get_config()
    ws = workspace
    sch = scheme or cfg["scheme"]
    wrapper = cfg["xcodebuild_wrapper"]
    device_id = xcodebuild_id or cfg["device_xcodebuild_id"]

    if not ws:
        return False, "workspace is required — pass the absolute path to the .xcworkspace"
    if not sch:
        return False, "No scheme configured. Set APP_SCHEME in pepper/.env"
    if not os.path.exists(ws):
        return False, f"Workspace not found: {ws}"
    if not device_id:
        return False, "No device xcodebuild ID configured. Set DEVICE_XCODEBUILD_ID in pepper/.env"

    cmd = [
        wrapper,
        "-workspace",
        ws,
        "-scheme",
        sch,
        "-configuration",
        "Debug",
        "-destination",
        f"platform=iOS,id={device_id}",
        "-skipPackagePluginValidation",
        "-skipMacroValidation",
        "DEBUG_INFORMATION_FORMAT=dwarf-with-dsym",
        "build",
    ]

    # Fall back to raw xcodebuild with manual DerivedData isolation
    custom_derived_data = None
    if not os.path.exists(wrapper):
        cmd[0] = "xcodebuild"
        ws_dir = os.path.dirname(os.path.abspath(ws))
        worktree_name = os.path.basename(ws_dir)
        custom_derived_data = f"/tmp/DerivedData-{worktree_name}"
        cmd.extend(["-derivedDataPath", custom_derived_data])

    proc = await asyncio.create_subprocess_exec(
        *cmd,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.STDOUT,
    )
    stdout, _ = await proc.communicate()
    output = stdout.decode("utf-8", errors="replace")

    if proc.returncode == 0:
        if custom_derived_data:
            _fix_prebuilt_artifacts(custom_derived_data)
        lines = output.strip().split("\n")
        summary = "\n".join(lines[-3:]) if len(lines) > 3 else output.strip()
        return True, f"BUILD SUCCEEDED (device)\n{summary}"
    else:
        return False, _extract_build_errors(output, "BUILD FAILED (device)")


async def install_on_device(devicectl_uuid: str, app_path: str) -> tuple[bool, str]:
    """Install app on physical device via devicectl."""
    proc = await asyncio.create_subprocess_exec(
        "xcrun",
        "devicectl",
        "device",
        "install",
        "app",
        "--device",
        devicectl_uuid,
        app_path,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.STDOUT,
    )
    stdout, _ = await proc.communicate()
    output = stdout.decode("utf-8", errors="replace").strip()
    if proc.returncode == 0:
        return True, "Installed on device"
    return False, f"Install failed: {output}"


async def launch_on_device(devicectl_uuid: str, bundle_id: str) -> tuple[bool, str]:
    """Launch app on physical device via devicectl."""
    proc = await asyncio.create_subprocess_exec(
        "xcrun",
        "devicectl",
        "device",
        "process",
        "launch",
        "--device",
        devicectl_uuid,
        "--terminate-existing",
        bundle_id,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.STDOUT,
    )
    stdout, _ = await proc.communicate()
    output = stdout.decode("utf-8", errors="replace").strip()
    if proc.returncode == 0:
        return True, "Launched on device"
    return False, f"Launch failed: {output}"

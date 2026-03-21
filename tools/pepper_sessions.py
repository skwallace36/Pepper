"""
Pepper session management — file-based coordination for multi-agent simulator access.

Each MCP server process (= one Claude Code session) claims a simulator by writing a
session file to /tmp/pepper-sessions/{UDID}.session. Other sessions see the claim and
pick a different simulator. Stale sessions (dead PID) are cleaned up automatically.

Designed for zero-config single-user use: if only one session exists, everything works
exactly as before. The session layer is purely additive.
"""

import json
import os
import socket
import time
from datetime import datetime, timezone
from typing import Optional


SESSION_DIR = "/tmp/pepper-sessions"
PORT_DIR = "/tmp/pepper-ports"

# How old a heartbeat can be before we consider the session stale (seconds).
# Secondary check — PID liveness is primary.
HEARTBEAT_STALE_SECONDS = 120

# Default cap on concurrent claimed simulators.
DEFAULT_MAX_SIMS = 3


# ---------------------------------------------------------------------------
# Liveness checks
# ---------------------------------------------------------------------------

def _is_pid_alive(pid: int) -> bool:
    """Check if a process with the given PID exists. Does not send a signal."""
    try:
        os.kill(pid, 0)
        return True
    except (ProcessLookupError, PermissionError):
        # ProcessLookupError: PID doesn't exist
        # PermissionError: PID exists but we can't signal it (still alive)
        return pid > 0 and not isinstance(
            _safe_kill(pid), ProcessLookupError
        )
    except OSError:
        return False


def _safe_kill(pid: int) -> Optional[Exception]:
    """Attempt os.kill(pid, 0), return the exception or None."""
    try:
        os.kill(pid, 0)
        return None
    except Exception as e:
        return e


def _is_pid_alive(pid: int) -> bool:
    """Check if a process with the given PID exists."""
    if pid <= 0:
        return False
    try:
        os.kill(pid, 0)
        return True
    except PermissionError:
        # Process exists but owned by another user — still alive
        return True
    except ProcessLookupError:
        return False
    except OSError:
        return False


def quick_port_check(port: int, timeout: float = 1.0) -> bool:
    """Check if anything is listening on localhost:port via TCP connect."""
    try:
        s = socket.create_connection(("localhost", port), timeout=timeout)
        s.close()
        return True
    except (ConnectionRefusedError, OSError, socket.timeout):
        return False


# ---------------------------------------------------------------------------
# Session file I/O
# ---------------------------------------------------------------------------

def _ensure_session_dir():
    """Create session directory if it doesn't exist."""
    os.makedirs(SESSION_DIR, exist_ok=True)


def _session_path(udid: str) -> str:
    return os.path.join(SESSION_DIR, f"{udid}.session")


def _read_session(udid: str) -> Optional[dict]:
    """Read a session file. Returns None if missing or corrupt."""
    path = _session_path(udid)
    try:
        with open(path) as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        return None


def _write_session_atomic(udid: str, data: dict) -> bool:
    """Write a session file atomically (write tmp, rename).

    Returns True if we successfully wrote AND verified our PID is in the file.
    This handles the race where two processes both try to claim the same sim:
    both write tmp files, both rename — only one rename wins on the same inode,
    and we re-read to confirm.
    """
    _ensure_session_dir()
    path = _session_path(udid)
    tmp_path = f"{path}.{os.getpid()}.tmp"
    try:
        with open(tmp_path, "w") as f:
            json.dump(data, f)
        os.rename(tmp_path, path)
        # Verify we won the race
        verify = _read_session(udid)
        return verify is not None and verify.get("pid") == os.getpid()
    except OSError:
        # Clean up tmp file on failure
        try:
            os.remove(tmp_path)
        except OSError:
            pass
        return False


def _remove_session(udid: str):
    """Remove a session file. Idempotent."""
    try:
        os.remove(_session_path(udid))
    except FileNotFoundError:
        pass
    except OSError:
        pass


# ---------------------------------------------------------------------------
# Session lifecycle
# ---------------------------------------------------------------------------

def _is_session_live(session: dict) -> bool:
    """Check if a session is still active.

    A session is live if EITHER:
    - The claiming PID is still alive (long-running MCP server), OR
    - The Pepper port is still responding (app is running, even if deploy script exited)

    This dual check supports both MCP deploy (PID stays alive) and `make deploy`
    (PID dies after launch, but the app + Pepper port remain live).
    """
    pid = session.get("pid", 0)
    port = session.get("port", 0)

    if _is_pid_alive(pid):
        # PID is alive — check heartbeat staleness as secondary signal
        heartbeat_str = session.get("heartbeat", "")
        if heartbeat_str:
            try:
                heartbeat_time = datetime.fromisoformat(heartbeat_str)
                age = (datetime.now(timezone.utc) - heartbeat_time).total_seconds()
                if age > HEARTBEAT_STALE_SECONDS:
                    # PID is alive but heartbeat is very old — could be PID reuse.
                    # Be conservative: treat as stale only if the port is also dead.
                    if port and not quick_port_check(port):
                        return False
            except (ValueError, TypeError):
                pass
        return True

    # PID is dead — but is the app still running?
    # This covers `make deploy` where the deploy script exits but the app stays up.
    if port and quick_port_check(port):
        return True

    return False


def claim_simulator(udid: str, bundle_id: str = "", port: int = 0,
                    label: Optional[str] = None) -> bool:
    """Attempt to exclusively claim a simulator for this process.

    Returns True if claim succeeded. Returns False if another live session owns it.
    Cleans up stale claims automatically.
    """
    existing = _read_session(udid)
    if existing:
        if existing.get("pid") == os.getpid():
            # We already own it — update
            heartbeat(udid, bundle_id=bundle_id, port=port)
            return True
        if _is_session_live(existing):
            # Another live session owns it
            return False
        # Stale session — remove and reclaim
        _remove_session(udid)

    now = datetime.now(timezone.utc).isoformat()
    data = {
        "udid": udid,
        "pid": os.getpid(),
        "claimed_at": now,
        "heartbeat": now,
        "bundle_id": bundle_id,
        "port": port,
        "label": label or os.environ.get("PEPPER_SESSION_LABEL", ""),
    }
    return _write_session_atomic(udid, data)


def claim_simulator_with_port(udid: str, bundle_id: str = "", port: int = 0,
                              label: Optional[str] = None) -> bool:
    """Claim a simulator using port liveness as the anchor (not PID).

    For use by short-lived scripts like `make deploy` where the claiming process
    exits immediately but the app (and its Pepper port) stays alive. The session
    is considered live as long as the port responds, regardless of PID.

    Uses PID 0 as a sentinel — _is_session_live will fall through to port check.
    """
    existing = _read_session(udid)
    if existing and _is_session_live(existing):
        # Another live session owns it — check if it's the same port (redeploy)
        if existing.get("port") == port:
            # Same port = same app instance, just update
            pass
        else:
            return False
    elif existing:
        _remove_session(udid)

    now = datetime.now(timezone.utc).isoformat()
    data = {
        "udid": udid,
        "pid": 0,  # sentinel — liveness determined by port check
        "claimed_at": now,
        "heartbeat": now,
        "bundle_id": bundle_id,
        "port": port,
        "label": label or os.environ.get("PEPPER_SESSION_LABEL", "make-deploy"),
    }
    # Write directly — no PID race to verify since we use port liveness
    _ensure_session_dir()
    path = _session_path(udid)
    tmp_path = f"{path}.{os.getpid()}.tmp"
    try:
        with open(tmp_path, "w") as f:
            json.dump(data, f)
        os.rename(tmp_path, path)
        return True
    except OSError:
        try:
            os.remove(tmp_path)
        except OSError:
            pass
        return False


def release_simulator(udid: str):
    """Release our claim on a simulator. Only removes if we own it (PID match)."""
    session = _read_session(udid)
    if session and session.get("pid") == os.getpid():
        _remove_session(udid)


def heartbeat(udid: str, bundle_id: str = "", port: int = 0):
    """Update heartbeat timestamp on our session. No-op if we don't own it."""
    session = _read_session(udid)
    if not session or session.get("pid") != os.getpid():
        return
    session["heartbeat"] = datetime.now(timezone.utc).isoformat()
    if bundle_id:
        session["bundle_id"] = bundle_id
    if port:
        session["port"] = port
    _write_session_atomic(udid, session)


def is_claimed(udid: str) -> Optional[dict]:
    """Check if a simulator is claimed by a live session.

    Returns session dict if claimed and live, None otherwise.
    Cleans up stale session as a side effect.
    """
    session = _read_session(udid)
    if not session:
        return None
    if _is_session_live(session):
        return session
    # Stale — clean up
    _remove_session(udid)
    return None


def my_session() -> Optional[str]:
    """Return the UDID claimed by this process, or None."""
    _ensure_session_dir()
    my_pid = os.getpid()
    try:
        for f in os.listdir(SESSION_DIR):
            if f.endswith(".session"):
                udid = f.removesuffix(".session")
                session = _read_session(udid)
                if session and session.get("pid") == my_pid:
                    return udid
    except OSError:
        pass
    return None


def list_sessions() -> list[dict]:
    """List all sessions with liveness status.

    Returns list of session dicts augmented with 'live': bool.
    """
    _ensure_session_dir()
    sessions = []
    try:
        for f in sorted(os.listdir(SESSION_DIR)):
            if f.endswith(".session"):
                udid = f.removesuffix(".session")
                session = _read_session(udid)
                if session:
                    session["live"] = _is_session_live(session)
                    sessions.append(session)
    except OSError:
        pass
    return sessions


def cleanup_stale():
    """Remove dead sessions and orphaned port files.

    Called opportunistically before resolving simulators.
    All operations are idempotent — safe to call from multiple processes.
    """
    _ensure_session_dir()

    # Clean stale session files
    try:
        for f in os.listdir(SESSION_DIR):
            if f.endswith(".session"):
                udid = f.removesuffix(".session")
                session = _read_session(udid)
                if session and not _is_session_live(session):
                    _remove_session(udid)
    except OSError:
        pass

    # Clean orphaned port files (port file exists but no session and port is dead)
    try:
        if os.path.isdir(PORT_DIR):
            for f in os.listdir(PORT_DIR):
                if f.endswith(".port"):
                    udid = f.removesuffix(".port")
                    port_path = os.path.join(PORT_DIR, f)
                    # If there's a live session for this sim, leave the port file alone
                    if is_claimed(udid):
                        continue
                    # No live session — check if port is actually listening
                    try:
                        port = int(open(port_path).read().strip())
                        if not quick_port_check(port):
                            try:
                                os.remove(port_path)
                            except OSError:
                                pass
                    except (ValueError, OSError):
                        # Corrupt port file — remove
                        try:
                            os.remove(port_path)
                        except OSError:
                            pass
    except OSError:
        pass


# ---------------------------------------------------------------------------
# Simulator provisioning (reuse-first, capped)
# ---------------------------------------------------------------------------

def _get_max_sims() -> int:
    """Get the max concurrent simulator cap from env or default."""
    try:
        return int(os.environ.get("PEPPER_MAX_SIMS", DEFAULT_MAX_SIMS))
    except (ValueError, TypeError):
        return DEFAULT_MAX_SIMS


def _count_claimed() -> int:
    """Count live claimed sessions."""
    return sum(1 for s in list_sessions() if s.get("live"))


def _list_port_files() -> list[dict]:
    """List simulators with port files (Pepper running or stale)."""
    sims = []
    if os.path.isdir(PORT_DIR):
        for f in sorted(os.listdir(PORT_DIR)):
            if f.endswith(".port"):
                udid = f.removesuffix(".port")
                try:
                    port = int(open(os.path.join(PORT_DIR, f)).read().strip())
                    sims.append({"udid": udid, "port": port})
                except (ValueError, OSError):
                    pass
    return sims


def _list_booted_sims() -> list[str]:
    """List UDIDs of all booted simulators."""
    import subprocess
    result = subprocess.run(
        ["xcrun", "simctl", "list", "devices", "booted", "-j"],
        capture_output=True, text=True
    )
    booted = []
    try:
        data = json.loads(result.stdout)
        for _runtime, devices in data.get("devices", {}).items():
            for d in devices:
                if d.get("state") == "Booted":
                    booted.append(d["udid"])
    except (json.JSONDecodeError, KeyError):
        pass
    return booted


def _list_available_iphones() -> list[dict]:
    """List available (not booted) iPhone simulators, newest runtime first, Pro preferred."""
    import subprocess
    result = subprocess.run(
        ["xcrun", "simctl", "list", "devices", "available", "-j"],
        capture_output=True, text=True
    )
    iphones = []
    try:
        data = json.loads(result.stdout)
        for runtime in sorted(data.get("devices", {}).keys(), reverse=True):
            if "iOS" not in runtime and "iphone" not in runtime.lower():
                continue
            for d in data["devices"][runtime]:
                if (d.get("isAvailable")
                        and "iPhone" in d.get("name", "")
                        and d.get("state") != "Booted"):
                    iphones.append(d)
    except (json.JSONDecodeError, KeyError):
        pass

    # Sort: Pro Max first, then Pro, then others
    def sort_key(d):
        name = d.get("name", "")
        if "Pro Max" in name:
            return 0
        if "Pro" in name:
            return 1
        return 2
    iphones.sort(key=sort_key)
    return iphones


def find_available_simulator() -> str:
    """Find an unclaimed simulator to use. Reuse-first, capped.

    Resolution order:
    1. Unclaimed sim with Pepper running (has live port file, no live session)
    2. Unclaimed booted sim (no Pepper yet — just needs deploy)
    3. Unbooted iPhone sim (boot it)
    4. All sims claimed up to cap — error

    Never creates new simulator devices.

    Returns UDID of the available simulator.
    Raises RuntimeError if none available.
    """
    cleanup_stale()
    max_sims = _get_max_sims()

    # 1. Unclaimed sim already running Pepper
    for s in _list_port_files():
        udid = s["udid"]
        if not is_claimed(udid):
            if quick_port_check(s["port"]):
                return udid

    # 2. Unclaimed booted sim
    claimed_udids = {s["udid"] for s in list_sessions() if s.get("live")}
    for udid in _list_booted_sims():
        if udid not in claimed_udids:
            return udid

    # Check cap before booting anything new
    if _count_claimed() >= max_sims:
        sessions = list_sessions()
        live = [s for s in sessions if s.get("live")]
        details = "\n".join(
            f"  {s['udid']} — PID {s['pid']}"
            + (f" ({s['label']})" if s.get("label") else "")
            for s in live
        )
        raise RuntimeError(
            f"All simulators in use ({len(live)}/{max_sims} claimed). "
            f"Wait for a session to finish, or increase PEPPER_MAX_SIMS.\n"
            f"Active sessions:\n{details}"
        )

    # 3. Boot an existing unbooted iPhone sim
    available = _list_available_iphones()
    for d in available:
        udid = d["udid"]
        if udid not in claimed_udids:
            return udid

    raise RuntimeError(
        "No available iPhone simulators found. "
        "Install one via Xcode > Settings > Platforms."
    )

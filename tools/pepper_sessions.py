"""
Pepper session management — file-based coordination for multi-agent simulator access.

Each MCP server process (= one Claude Code session) claims a simulator by writing a
session file to /tmp/pepper-sessions/{UDID}.session. Other sessions see the claim and
pick a different simulator. Stale sessions (dead PID) are cleaned up automatically.

Designed for zero-config single-user use: if only one session exists, everything works
exactly as before. The session layer is purely additive.
"""
from __future__ import annotations

import json
import logging
import os
import socket
from datetime import datetime, timezone

logger = logging.getLogger(__name__)


SESSION_DIR = "/tmp/pepper-sessions"
PORT_DIR = "/tmp/pepper-ports"

# How old a heartbeat can be before we consider the session stale (seconds).
# Secondary check — PID liveness is primary.
HEARTBEAT_STALE_SECONDS = 120

# Hard ceiling on session age (seconds). Sessions older than this are stale
# regardless of PID/port status. 20 min = 15-min agent timeout + 5-min buffer.
MAX_SESSION_AGE_SECONDS = 1200

# Default cap on concurrent claimed simulators.
DEFAULT_MAX_SIMS = 1


# ---------------------------------------------------------------------------
# Liveness checks
# ---------------------------------------------------------------------------

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
    except (TimeoutError, ConnectionRefusedError, OSError):
        return False


# ---------------------------------------------------------------------------
# Session file I/O
# ---------------------------------------------------------------------------

def _ensure_session_dir():
    """Create session directory if it doesn't exist."""
    os.makedirs(SESSION_DIR, exist_ok=True)


def _session_path(udid: str) -> str:
    return os.path.join(SESSION_DIR, f"{udid}.session")


def _read_session(udid: str) -> dict | None:
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
    Used by claim_simulator() for MCP server sessions (long-running PID).
    For deploy pre-claims, use claim_simulator_deploying() which uses flock.
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

    A session is live if ANY of:
    - state is "deploying" and claimed < 60s ago (deploy in progress)
    - The claiming PID is still alive (long-running MCP server)
    - The Pepper port is still responding (app running, deploy script exited)

    Hard ceiling: sessions older than MAX_SESSION_AGE_SECONDS are always stale,
    regardless of PID or port status.

    This supports: MCP deploy (PID alive), `make deploy` (port alive), and
    pre-claims during deploy (state=deploying, no port yet).
    """
    # Hard ceiling — catch hung processes that are technically alive
    claimed_str = session.get("claimed_at", "")
    if claimed_str:
        try:
            claimed_time = datetime.fromisoformat(claimed_str)
            age = (datetime.now(timezone.utc) - claimed_time).total_seconds()
            if age > MAX_SESSION_AGE_SECONDS:
                logger.info(
                    "Time-based stale cleanup: session %s (PID %s) aged out at %.0fs (max %ds)",
                    session.get("udid", "?"), session.get("pid", 0),
                    age, MAX_SESSION_AGE_SECONDS,
                )
                return False
        except (ValueError, TypeError):
            pass

    state = session.get("state", "active")
    pid = session.get("pid", 0)
    port = session.get("port", 0)

    # Pre-claim: deploy in progress, no port yet. Live for up to 60s.
    if state == "deploying":
        claimed_str = session.get("claimed_at", "")
        try:
            claimed_time = datetime.fromisoformat(claimed_str)
            age = (datetime.now(timezone.utc) - claimed_time).total_seconds()
            if age < 60:
                return True
            # Deploy took too long — treat as stale
        except (ValueError, TypeError):
            pass
        return False

    if _is_pid_alive(pid):
        # PID is alive — check heartbeat staleness as secondary signal
        heartbeat_str = session.get("heartbeat", "")
        if heartbeat_str:
            try:
                heartbeat_time = datetime.fromisoformat(heartbeat_str)
                age = (datetime.now(timezone.utc) - heartbeat_time).total_seconds()
                if age > HEARTBEAT_STALE_SECONDS and port and not quick_port_check(port):
                    # PID is alive but heartbeat is very old — could be PID reuse.
                    # Be conservative: treat as stale only if the port is also dead.
                    return False
            except (ValueError, TypeError):
                pass
        return True

    # PID is dead — but is the app still running?
    # This covers `make deploy` where the deploy script exits but the app stays up.
    return bool(port and quick_port_check(port))


def claim_simulator(udid: str, bundle_id: str = "", port: int = 0,
                    label: str | None = None) -> bool:
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


def claim_simulator_deploying(udid: str, label: str | None = None) -> bool:
    """Pre-claim a simulator before deploy starts.

    Writes a session with state=deploying. This is considered live for 60s,
    giving the deploy process time to launch the app and update to state=active.

    Uses fcntl.flock on a lockfile for true mutual exclusion between processes.

    Returns True if pre-claim succeeded, False if another session owns it.
    """
    import fcntl

    _ensure_session_dir()
    lock_path = os.path.join(SESSION_DIR, f"{udid}.lock")

    try:
        lock_fd = os.open(lock_path, os.O_CREAT | os.O_RDWR)
        try:
            # Non-blocking exclusive lock — if another process holds it, fail immediately
            fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except (OSError, BlockingIOError):
            os.close(lock_fd)
            return False

        try:
            # Inside the lock: check-then-write is now atomic
            existing = _read_session(udid)
            if existing and _is_session_live(existing):
                return False
            if existing:
                _remove_session(udid)

            now = datetime.now(timezone.utc).isoformat()
            data = {
                "udid": udid,
                "pid": 0,
                "claimed_at": now,
                "heartbeat": now,
                "state": "deploying",
                "bundle_id": "",
                "port": 0,
                "label": label or os.environ.get("PEPPER_SESSION_LABEL", "make-deploy"),
            }
            path = _session_path(udid)
            tmp_path = f"{path}.{os.getpid()}.tmp"
            with open(tmp_path, "w") as f:
                json.dump(data, f)
            os.rename(tmp_path, path)
            return True
        finally:
            fcntl.flock(lock_fd, fcntl.LOCK_UN)
            os.close(lock_fd)
    except OSError:
        return False


def claim_simulator_with_port(udid: str, bundle_id: str = "", port: int = 0,
                              label: str | None = None) -> bool:
    """Claim a simulator using port liveness as the anchor (not PID).

    For use by short-lived scripts like `make deploy` where the claiming process
    exits immediately but the app (and its Pepper port) stays alive. The session
    is considered live as long as the port responds, regardless of PID.

    Uses PID 0 as a sentinel — _is_session_live will fall through to port check.
    """
    existing = _read_session(udid)
    if existing and _is_session_live(existing):
        existing_state = existing.get("state", "active")
        if existing_state == "deploying":
            # Upgrade pre-claim to active — this is the post-deploy step
            pass
        elif existing.get("port") == port:
            # Same port = same app instance, just update
            pass
        else:
            # Another active session owns it
            return False
    elif existing:
        _remove_session(udid)

    now = datetime.now(timezone.utc).isoformat()
    data = {
        "udid": udid,
        "pid": 0,  # sentinel — liveness determined by port check
        "state": "active",
        "claimed_at": existing.get("claimed_at", now) if existing else now,
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


def is_claimed(udid: str) -> dict | None:
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


def my_session() -> str | None:
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
        if not is_claimed(udid) and quick_port_check(s["port"]):
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

    # 3. Boot an existing unbooted iPhone sim — only if no booted sims exist at all
    booted = _list_booted_sims()
    if not booted:
        available = _list_available_iphones()
        for d in available:
            udid = d["udid"]
            if udid not in claimed_udids:
                return udid

    raise RuntimeError(
        "No available simulators. Boot one manually or wait for a session to finish."
    )

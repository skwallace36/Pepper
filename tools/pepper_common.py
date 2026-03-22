"""
Pepper common utilities — shared constants and config helpers.

Used by pepper-mcp, pepper-ctl, pepper-stream, and test-client.py.
"""

import os


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

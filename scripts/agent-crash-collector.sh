#!/bin/bash
# scripts/agent-crash-collector.sh — detect and parse simulator crash reports
# Usage: agent-crash-collector.sh <start_epoch> [app_name]
# Output: JSON lines (one per crash) to stdout
#
# Scans ~/Library/Logs/DiagnosticReports for .ips files created after
# start_epoch matching app_name (default: PepperTestApp). Extracts crash
# signatures with exception type, top frames, Pepper involvement, and
# dedupe keys.

set -euo pipefail

START_EPOCH="${1:?Usage: agent-crash-collector.sh <start_epoch> [app_name]}"
APP_NAME="${2:-PepperTestApp}"
CRASH_DIR="$HOME/Library/Logs/DiagnosticReports"

[ -d "$CRASH_DIR" ] || exit 0

python3 - "$START_EPOCH" "$APP_NAME" "$CRASH_DIR" <<'PYEOF'
import json, sys, os, hashlib
from datetime import datetime, timezone

start_epoch = int(sys.argv[1])
app_name = sys.argv[2]
crash_dir = sys.argv[3]

# System image names — excluded when building crash signatures
SYSTEM_IMAGES = frozenset([
    "dyld", "libdyld.dylib", "libsystem_kernel.dylib",
    "libsystem_platform.dylib", "libsystem_pthread.dylib",
    "libobjc.A.dylib", "CoreFoundation", "Foundation",
    "UIKitCore", "libdispatch.dylib", "libsystem_c.dylib",
    "libsystem_malloc.dylib", "libsystem_blocks.dylib",
    "GraphicsServices", "FrontBoardServices",
])

def parse_crash(path):
    """Parse an .ips crash file, return a crash info dict or None."""
    try:
        with open(path) as f:
            lines = f.readlines()
        if len(lines) < 2:
            return None

        header = json.loads(lines[0])
        proc = header.get("name", "") or header.get("procName", "")
        bundle = header.get("bundleID", "")

        # Filter to our app
        if app_name not in proc and app_name.lower() not in bundle.lower():
            return None

        body = json.loads("".join(lines[1:]))

        # Exception info
        exc = body.get("exception", {})
        exc_type = exc.get("type", "unknown")
        signal = exc.get("signal", "unknown")
        subtype = exc.get("subtype", "")

        # Termination info (fallback)
        if exc_type == "unknown":
            term = body.get("termination", {})
            exc_type = term.get("code", "unknown")
            signal = term.get("signal", signal)

        # Image lookup table
        images = body.get("usedImages", [])
        def image_name(idx):
            try:
                return images[idx].get("name", f"image_{idx}")
            except (IndexError, TypeError):
                return f"image_{idx}"

        # Faulting thread frames
        fault_idx = body.get("faultingThread", 0)
        threads = body.get("threads", [])
        if fault_idx >= len(threads):
            return None

        frames = threads[fault_idx].get("frames", [])

        # Resolve frame symbols
        resolved = []
        for frame in frames:
            img_idx = frame.get("imageIndex", -1)
            img = image_name(img_idx)
            sym = frame.get("symbol", "")
            if not sym:
                offset = frame.get("imageOffset", 0)
                sym = f"{img}+0x{offset:x}" if isinstance(offset, int) else f"{img}+{offset}"
            resolved.append({"image": img, "symbol": sym})

        # Top 3 non-system frames for signature
        sig_frames = []
        for f in resolved:
            if f["image"] not in SYSTEM_IMAGES:
                sig_frames.append(f)
                if len(sig_frames) >= 3:
                    break

        # Check if Pepper.framework is in the stack
        pepper_in_stack = any(
            "Pepper" in f["image"] or "pepper" in f["symbol"].lower()
            for f in resolved
        )

        # Top 5 frames for display (skip pure system noise)
        display_frames = []
        for f in resolved:
            display_frames.append(f"{f['image']}:{f['symbol']}")
            if len(display_frames) >= 5:
                break

        # Dedupe key: hash of exception type + top 3 non-system frame symbols
        sig_str = exc_type + "|" + "|".join(f["symbol"] for f in sig_frames)
        dedupe_key = hashlib.sha256(sig_str.encode()).hexdigest()[:12]

        return {
            "file": os.path.basename(path),
            "exc_type": exc_type,
            "signal": signal,
            "subtype": subtype[:100] if subtype else "",
            "pepper_in_stack": pepper_in_stack,
            "dedupe_key": dedupe_key,
            "top_frames": display_frames,
            "sig_frames": [f["symbol"] for f in sig_frames],
        }
    except (json.JSONDecodeError, KeyError, IndexError, OSError):
        return None


# Scan for crash files newer than start_epoch
crashes = []
for fname in os.listdir(crash_dir):
    if not fname.endswith(".ips"):
        continue
    fpath = os.path.join(crash_dir, fname)
    try:
        mtime = os.path.getmtime(fpath)
        if mtime >= start_epoch:
            info = parse_crash(fpath)
            if info:
                crashes.append(info)
    except OSError:
        continue

# Output one JSON line per crash
for crash in sorted(crashes, key=lambda c: c["file"]):
    print(json.dumps(crash, separators=(",", ":")))
PYEOF

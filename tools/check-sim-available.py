#!/usr/bin/env python3
"""Pre-deploy check: block if another session owns this simulator."""
import sys
import os

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from pepper_sessions import is_claimed, find_available_simulator

udid = sys.argv[1] if len(sys.argv) > 1 else ""
if not udid:
    sys.exit(0)

session = is_claimed(udid)
if not session:
    sys.exit(0)

# Simulator is claimed — block deploy
label = session.get("label", "unknown")
port = session.get("port", "?")
print(f"ERROR: Simulator {udid} is claimed by another session ({label}, port {port}).", file=sys.stderr)

# Suggest an alternative
try:
    alt = find_available_simulator()
    print(f"  Try: make deploy SIMULATOR_ID={alt}", file=sys.stderr)
except RuntimeError:
    print("  No unclaimed simulators available. Wait for the other session to finish.", file=sys.stderr)

sys.exit(1)

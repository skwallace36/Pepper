#!/usr/bin/env python3
"""Pre-deploy check + pre-claim: atomically claim the simulator before deploying.

If another session owns the sim, blocks with exit 1 and suggests an alternative.
If unclaimed, writes a pre-claim session (state=deploying) so other agents see it
immediately — before the app is even launched.

The Makefile's post-launch claim updates this to state=active with the real port.
"""
import sys
import os

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from pepper_sessions import is_claimed, find_available_simulator, claim_simulator_deploying

udid = sys.argv[1] if len(sys.argv) > 1 else ""
if not udid:
    sys.exit(0)

# Try to pre-claim atomically. This checks for existing claims AND writes ours.
ok = claim_simulator_deploying(udid)
if ok:
    sys.exit(0)

# Claim failed — another session owns it
session = is_claimed(udid)
label = session.get("label", "unknown") if session else "unknown"
port = session.get("port", "?") if session else "?"
print(f"ERROR: Simulator {udid} is claimed by another session ({label}, port {port}).", file=sys.stderr)

try:
    alt = find_available_simulator()
    print(f"  Try: make deploy SIMULATOR_ID={alt}", file=sys.stderr)
except RuntimeError:
    print("  No unclaimed simulators available. Wait for the other session to finish.", file=sys.stderr)

sys.exit(1)

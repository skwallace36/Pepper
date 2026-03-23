#!/usr/bin/env python3
"""
pepper interactive test client.

Connect to the pepper websocket server and send commands interactively.
"""

import asyncio
import json
import os
import sys
import uuid
from collections import OrderedDict

try:
    import websockets
except ImportError:
    print("Error: 'websockets' package required. Install with: pip install websockets", file=sys.stderr)
    sys.exit(1)

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from pepper_common import DEFAULT_HOST
from pepper_common import discover_port as _discover_port


def discover_port(simulator=None):
    """Auto-discover Pepper port, falling back to 8765 for CLI use."""
    try:
        return _discover_port(simulator=simulator, fallback=8765)
    except RuntimeError as e:
        print(str(e), file=sys.stderr)
        sys.exit(1)

# Command shortcuts: name -> (cmd, params_template)
SHORTCUTS = OrderedDict([
    ("ping",       ("ping", None)),
    ("screen",     ("screen", None)),
    ("snapshot",   ("snapshot", None)),
    ("tree",       ("tree", None)),
    ("screenshot", ("screenshot", None)),
    ("back",       ("back", None)),
])

# Shortcuts with arguments: name -> (cmd, param_name)
ARG_SHORTCUTS = OrderedDict([
    ("nav",    ("navigate", "to")),
    ("tap",    ("tap", "element")),
    ("input",  ("input", "element")),  # second arg is value
    ("toggle", ("toggle", "element")),
    ("scroll", ("scroll", "element")),
    ("read",   ("read", "element")),
    ("sub",    ("subscribe", "events")),
])


def make_command(cmd, params=None):
    """Build a command message."""
    msg = {
        "id": str(uuid.uuid4())[:8],
        "cmd": cmd,
    }
    if params:
        msg["params"] = params
    return msg


def pretty_json(obj):
    """Format JSON for display."""
    return json.dumps(obj, indent=2, ensure_ascii=False)


def parse_input(line):
    """Parse user input into a command dict."""
    line = line.strip()
    if not line:
        return None

    # Raw JSON
    if line.startswith("{"):
        try:
            obj = json.loads(line)
            if "id" not in obj:
                obj["id"] = str(uuid.uuid4())[:8]
            return obj
        except json.JSONDecodeError as e:
            print(f"  Invalid JSON: {e}")
            return None

    parts = line.split()
    name = parts[0].lower()
    args = parts[1:]

    # No-arg shortcuts
    if name in SHORTCUTS:
        cmd, params = SHORTCUTS[name]
        return make_command(cmd, params)

    # Arg shortcuts
    if name in ARG_SHORTCUTS:
        cmd, param_name = ARG_SHORTCUTS[name]
        if not args:
            print(f"  Usage: {name} <{param_name}>")
            return None
        if name == "input" and len(args) >= 2:
            # input <element> <value...>
            return make_command(cmd, {"element": args[0], "value": " ".join(args[1:])})
        if name == "sub":
            return make_command(cmd, {"events": args})
        return make_command(cmd, {param_name: args[0]})

    # Generic: treat first word as cmd, rest as key=value or positional
    params = {}
    for arg in args:
        if "=" in arg:
            k, v = arg.split("=", 1)
            # Try to parse as JSON value
            try:
                v = json.loads(v)
            except (json.JSONDecodeError, ValueError):
                pass
            params[k] = v
    return make_command(name, params if params else None)


def print_help():
    """Print available commands."""
    print("\n  Built-in shortcuts:")
    print("  -------------------")
    for name, (cmd, _) in SHORTCUTS.items():
        print(f"    {name:<12} -> {cmd}")
    print()
    for name, (cmd, param) in ARG_SHORTCUTS.items():
        print(f"    {name} <{param}>" + " " * max(0, 8 - len(param)) + f" -> {cmd}")
    print()
    print("  Special:")
    print("    input <element> <value>   -> input (set text field)")
    print("    sub <event1> <event2>     -> subscribe to events")
    print()
    print("  Or send any command:")
    print("    <cmd> [key=value ...]")
    print("    {\"cmd\": \"...\", ...}       (raw JSON)")
    print()
    print("  Control:")
    print("    help       Show this help")
    print("    quit       Disconnect and exit")
    print()


class PepperClient:
    def __init__(self, host, port):
        self.host = host
        self.port = port
        self.ws = None
        self.running = False

    @property
    def url(self):
        return f"ws://{self.host}:{self.port}"

    async def connect(self):
        """Connect to the server."""
        print(f"  Connecting to {self.url}...")
        try:
            self.ws = await websockets.connect(self.url, compression=None)
            print("  Connected.")
            return True
        except (ConnectionRefusedError, OSError) as e:
            print(f"  Connection failed: {e}")
            return False

    async def send(self, msg):
        """Send a command and wait for a response.

        Filters out event messages (e.g. log events) while waiting,
        printing them inline so the user can see server activity.
        """
        raw = json.dumps(msg)
        msg_id = msg.get("id")
        try:
            assert self.ws is not None
            await self.ws.send(raw)
            deadline = asyncio.get_event_loop().time() + 10.0
            while True:
                remaining = deadline - asyncio.get_event_loop().time()
                if remaining <= 0:
                    print("  Timeout waiting for response.")
                    return None
                frame = await asyncio.wait_for(self.ws.recv(), timeout=remaining)
                data = json.loads(frame)
                # Log events are broadcast asynchronously; show them but keep waiting
                if "event" in data:
                    evt = data["event"]
                    evt_data = data.get("data", {})
                    level = evt_data.get("level", "")
                    message = evt_data.get("message", "")
                    if evt == "log" and message:
                        print(f"  [{evt}:{level}] {message}")
                    else:
                        print(f"  [event:{evt}] {pretty_json(evt_data)}")
                    continue
                # Accept response matching our id, or any non-event message
                if msg_id is None or data.get("id") == msg_id:
                    return data
        except TimeoutError:
            print("  Timeout waiting for response.")
            return None
        except websockets.exceptions.ConnectionClosed:
            print("  Connection lost.")
            self.ws = None
            return None

    async def listen_events(self):
        """Background task to print events."""
        try:
            while self.running and self.ws:
                try:
                    msg = await asyncio.wait_for(self.ws.recv(), timeout=0.1)
                    data = json.loads(msg)
                    if "event" in data:
                        print(f"\n  [event] {data['event']}: {pretty_json(data.get('data', {}))}")
                        print("fi> ", end="", flush=True)
                except TimeoutError:
                    continue
                except websockets.exceptions.ConnectionClosed:
                    break
        except asyncio.CancelledError:
            pass

    async def reconnect(self):
        """Try to reconnect."""
        print("  Attempting to reconnect...")
        for attempt in range(3):
            await asyncio.sleep(1)
            if await self.connect():
                return True
            print(f"  Retry {attempt + 1}/3...")
        print("  Could not reconnect. Use Ctrl+C to exit.")
        return False

    async def repl(self):
        """Interactive command loop."""
        self.running = True
        print_help()
        print("  Ready. Type a command or 'help'.\n")

        loop = asyncio.get_event_loop()

        while self.running:
            try:
                # Read input in executor to not block event loop
                line = await loop.run_in_executor(None, lambda: input("fi> "))
            except (EOFError, KeyboardInterrupt):
                print("\n  Goodbye.")
                break

            line = line.strip()
            if not line:
                continue
            if line.lower() in ("quit", "exit", "q"):
                print("  Goodbye.")
                break
            if line.lower() in ("help", "h", "?"):
                print_help()
                continue

            msg = parse_input(line)
            if msg is None:
                continue

            # Show what we're sending
            print(f"  -> {json.dumps(msg)}")

            if self.ws is None and not await self.reconnect():
                continue

            response = await self.send(msg)
            if response is not None:
                status = response.get("status", "?")
                if status == "ok":
                    print(f"  <- \033[32m{status}\033[0m")
                else:
                    print(f"  <- \033[31m{status}\033[0m")
                if response.get("data"):
                    print(f"  {pretty_json(response['data'])}")
            elif self.ws is None:
                await self.reconnect()

        self.running = False
        if self.ws:
            await self.ws.close()


async def main():
    import argparse

    parser = argparse.ArgumentParser(description="pepper interactive test client")
    parser.add_argument("--host", default=DEFAULT_HOST, help=f"Server host (default: {DEFAULT_HOST})")
    parser.add_argument("--port", "-p", type=int, default=None, help="Server port (default: auto-discover)")
    parser.add_argument("--simulator", "-s", default=None, help="Simulator UDID")
    args = parser.parse_args()

    if args.port is None:
        args.port = discover_port(simulator=args.simulator)

    client = PepperClient(args.host, args.port)
    if not await client.connect():
        print("  Tip: Make sure the app is running with the Pepper control plane enabled.")
        print("  Start the REPL anyway? Commands will reconnect when the server is up.")
        try:
            answer = input("  [y/N] ")
        except (EOFError, KeyboardInterrupt):
            print()
            return
        if answer.lower() not in ("y", "yes"):
            return

    await client.repl()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        print("\n  Interrupted.")

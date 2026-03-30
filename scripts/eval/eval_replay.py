#!/usr/bin/env python3
"""MCP replay server that serves recorded tool responses.

Reads a recording.jsonl fixture and responds to tool calls by matching
against recorded interactions. Used for fast prompt iteration without a
running simulator.

Usage:
    # As MCP server (called by Claude via .mcp.json):
    python3 scripts/eval/eval_replay.py --fixture recording.jsonl --serve

    # Test matching locally:
    python3 scripts/eval/eval_replay.py --fixture recording.jsonl --test '{"tool":"mcp__pepper__look","input":{}}'

    # Inspect a fixture:
    python3 scripts/eval/eval_replay.py --fixture recording.jsonl
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

PEPPER_TOOLS = [
    "look", "tap", "scroll", "scroll_to", "swipe", "gesture",
    "input_text", "toggle", "navigate", "back", "dismiss",
    "dismiss_keyboard", "dialog", "screen", "screenshot", "snapshot",
    "diff", "vars_inspect", "heap", "layers", "console", "network",
    "timeline", "crash_log", "animations", "lifecycle", "find",
    "read_element", "tree", "highlight", "hook", "defaults",
    "clipboard", "keychain", "cookies", "locale", "flags", "push",
    "orientation", "appearance", "dynamic_type", "status", "wait_for",
    "wait_idle", "record", "raw", "simulator", "build_sim",
    "build_hardware", "deploy_sim", "iterate", "constraints",
    "accessibility_action", "accessibility_audit", "accessibility_events",
    "concurrency", "coredata", "notifications", "perf", "renders",
    "responder_chain", "sandbox", "storage", "timers", "undo_manager",
    "webview",
]


class ReplayMatcher:
    """Match incoming tool calls against recorded fixtures."""

    def __init__(self, fixture_path: str):
        self.recordings = self._load(fixture_path)
        self.cursor = 0

    def _load(self, path: str) -> list[dict]:
        recs = []
        for line in Path(path).read_text().splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                recs.append(json.loads(line))
            except json.JSONDecodeError:
                continue
        return recs

    def match(self, tool_name: str, tool_input: dict) -> tuple[str, bool]:
        """Find best matching response. Returns (response_text, is_error).

        Strategy:
        1. Sequential: if next unconsumed recording matches tool_name, use it
        2. Exact: same tool_name + same input params in remaining recordings
        3. Tool-name: same tool_name anywhere in remaining recordings
        4. Fallback: generic error
        """
        # Sequential match
        if self.cursor < len(self.recordings):
            rec = self.recordings[self.cursor]
            if rec["tool"] == tool_name:
                self.cursor += 1
                return rec["response"], rec.get("is_error", False)

        # Exact match
        for i in range(self.cursor, len(self.recordings)):
            rec = self.recordings[i]
            if rec["tool"] == tool_name and rec["input"] == tool_input:
                self.cursor = i + 1
                return rec["response"], rec.get("is_error", False)

        # Tool-name match
        for i in range(self.cursor, len(self.recordings)):
            rec = self.recordings[i]
            if rec["tool"] == tool_name:
                self.cursor = i + 1
                return rec["response"], rec.get("is_error", False)

        # Fallback
        return json.dumps({
            "status": "error",
            "error": f"[REPLAY] No recorded response for {tool_name}. "
                     f"Recording has {len(self.recordings)} entries, "
                     f"cursor at {self.cursor}.",
        }), True


def serve_stdio(matcher: ReplayMatcher) -> None:
    """Run as a minimal MCP server over stdio using JSON-RPC."""

    def send(msg: dict) -> None:
        data = json.dumps(msg)
        sys.stdout.write(f"Content-Length: {len(data)}\r\n\r\n{data}")
        sys.stdout.flush()

    def read_message() -> dict | None:
        header = ""
        while True:
            ch = sys.stdin.read(1)
            if not ch:
                return None
            header += ch
            if header.endswith("\r\n\r\n"):
                break
        length = 0
        for line in header.strip().split("\r\n"):
            if line.lower().startswith("content-length:"):
                length = int(line.split(":")[1].strip())
        if length == 0:
            return None
        body = sys.stdin.read(length)
        return json.loads(body)

    while True:
        msg = read_message()
        if msg is None:
            break

        method = msg.get("method", "")
        msg_id = msg.get("id")

        if method == "initialize":
            send({
                "jsonrpc": "2.0",
                "id": msg_id,
                "result": {
                    "protocolVersion": "2024-11-05",
                    "serverInfo": {"name": "pepper-replay", "version": "0.1.0"},
                    "capabilities": {"tools": {}},
                },
            })
        elif method == "notifications/initialized":
            pass
        elif method == "tools/list":
            tools = []
            for name in PEPPER_TOOLS:
                tools.append({
                    "name": name,
                    "description": f"[REPLAY] {name}",
                    "inputSchema": {
                        "type": "object",
                        "properties": {
                            "simulator": {"type": "string", "description": "Simulator UDID"},
                        },
                    },
                })
            send({
                "jsonrpc": "2.0",
                "id": msg_id,
                "result": {"tools": tools},
            })
        elif method == "tools/call":
            params = msg.get("params", {})
            tool_name = params.get("name", "")
            tool_input = params.get("arguments", {})

            full_name = f"mcp__pepper__{tool_name}" if not tool_name.startswith("mcp__") else tool_name
            response, is_error = matcher.match(full_name, tool_input)

            send({
                "jsonrpc": "2.0",
                "id": msg_id,
                "result": {
                    "content": [{"type": "text", "text": response}],
                    "isError": is_error,
                },
            })
        elif msg_id is not None:
            send({
                "jsonrpc": "2.0",
                "id": msg_id,
                "error": {"code": -32601, "message": f"Unknown method: {method}"},
            })


def main() -> None:
    parser = argparse.ArgumentParser(description="MCP replay server.")
    parser.add_argument("--fixture", required=True, help="Path to recording.jsonl")
    parser.add_argument("--serve", action="store_true", help="Run as MCP stdio server")
    parser.add_argument("--test", help="Test matching: JSON with tool and input")
    args = parser.parse_args()

    matcher = ReplayMatcher(args.fixture)

    if args.serve:
        serve_stdio(matcher)
    elif args.test:
        query = json.loads(args.test)
        resp, is_err = matcher.match(query["tool"], query.get("input", {}))
        print(f"Error: {is_err}")
        print(f"Response: {resp[:500]}")
    else:
        print(f"Loaded {len(matcher.recordings)} recordings from {args.fixture}")
        for i, rec in enumerate(matcher.recordings[:10]):
            print(f"  [{i}] {rec['tool']} -> {str(rec['response'])[:80]}...")
        if len(matcher.recordings) > 10:
            print(f"  ... and {len(matcher.recordings) - 10} more")


if __name__ == "__main__":
    main()

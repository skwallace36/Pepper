#!/usr/bin/env python3
"""Parse Claude CLI verbose stream-json logs into structured tool-call timelines.

Reads line-delimited JSON from `claude -p ... --output-format stream-json --verbose`
and produces an EvalTranscript with paired tool calls, reread detection, wasted-call
detection, and per-tool counts.

Usage:
    python3 scripts/eval/eval_transcript.py --log build/logs/some-verbose.log
    python3 scripts/eval/eval_transcript.py --log build/logs/some-verbose.log --json
"""

from __future__ import annotations

import argparse
import json
import sys
from collections import Counter
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

RESPONSE_TRUNCATE = 2000


@dataclass
class ToolCall:
    index: int
    tool_name: str
    tool_input: dict
    response_text: str
    is_error: bool
    response_bytes: int
    pepper_command: str | None
    is_reread: bool
    is_wasted: bool

    def to_dict(self) -> dict:
        return {
            "index": self.index,
            "tool_name": self.tool_name,
            "tool_input": self.tool_input,
            "response_text": self.response_text,
            "is_error": self.is_error,
            "response_bytes": self.response_bytes,
            "pepper_command": self.pepper_command,
            "is_reread": self.is_reread,
            "is_wasted": self.is_wasted,
        }


@dataclass
class EvalTranscript:
    session_id: str
    model: str
    tool_calls: list[ToolCall]
    text_blocks: list[str]
    total_cost_usd: float
    num_turns: int
    duration_ms: int
    stop_reason: str
    # Derived
    tool_counts: dict[str, int] = field(default_factory=dict)
    pepper_tool_counts: dict[str, int] = field(default_factory=dict)
    files_read: dict[str, int] = field(default_factory=dict)
    reread_count: int = 0
    wasted_call_count: int = 0
    error_count: int = 0

    def __post_init__(self) -> None:
        self._compute_derived()

    def _compute_derived(self) -> None:
        tool_counter: Counter[str] = Counter()
        pepper_counter: Counter[str] = Counter()
        files: Counter[str] = Counter()

        for tc in self.tool_calls:
            tool_counter[tc.tool_name] += 1
            if tc.pepper_command:
                pepper_counter[tc.pepper_command] += 1
            if tc.tool_name == "Read":
                fp = tc.tool_input.get("file_path", "")
                if fp:
                    files[fp] += 1

        self.tool_counts = dict(tool_counter)
        self.pepper_tool_counts = dict(pepper_counter)
        self.files_read = dict(files)
        self.reread_count = sum(1 for tc in self.tool_calls if tc.is_reread)
        self.wasted_call_count = sum(1 for tc in self.tool_calls if tc.is_wasted)
        self.error_count = sum(1 for tc in self.tool_calls if tc.is_error)

    def to_dict(self) -> dict:
        return {
            "session_id": self.session_id,
            "model": self.model,
            "tool_calls": [tc.to_dict() for tc in self.tool_calls],
            "text_blocks": self.text_blocks,
            "total_cost_usd": self.total_cost_usd,
            "num_turns": self.num_turns,
            "duration_ms": self.duration_ms,
            "stop_reason": self.stop_reason,
            "tool_counts": self.tool_counts,
            "pepper_tool_counts": self.pepper_tool_counts,
            "files_read": self.files_read,
            "reread_count": self.reread_count,
            "wasted_call_count": self.wasted_call_count,
            "error_count": self.error_count,
        }


def _extract_pepper_command(tool_name: str, tool_input: dict | None = None) -> str | None:
    """Extract pepper command from tool name or Bash command string.

    Handles both:
    - Direct MCP calls: mcp__pepper__look -> look
    - Bash-based calls: pepper-ctl look ... -> look
    """
    prefix = "mcp__pepper__"
    if tool_name.startswith(prefix):
        return tool_name[len(prefix):]

    # Detect pepper-ctl calls in Bash commands
    if tool_name == "Bash" and tool_input:
        cmd = tool_input.get("command", "")
        import re
        match = re.search(r"pepper-ctl\s+(\w+)", cmd)
        if match:
            return match.group(1)

    return None


def _response_is_error(content: Any) -> bool:
    if isinstance(content, dict):
        return content.get("is_error", False) or content.get("type") == "error"
    if isinstance(content, str):
        lower = content.lower()
        return lower.startswith("error") or lower.startswith("traceback")
    if isinstance(content, list):
        for block in content:
            if isinstance(block, dict) and block.get("type") == "error":
                return True
    return False


def _stringify_content(content: Any) -> str:
    if isinstance(content, str):
        return content
    if isinstance(content, dict):
        text = content.get("text") or content.get("output") or content.get("content")
        if isinstance(text, str):
            return text
        return json.dumps(content)
    if isinstance(content, list):
        parts = []
        for block in content:
            if isinstance(block, dict):
                parts.append(block.get("text", json.dumps(block)))
            elif isinstance(block, str):
                parts.append(block)
        return "\n".join(parts)
    return str(content)


def parse_verbose_log(path: str) -> EvalTranscript:
    """Parse a Claude CLI verbose stream-json log into an EvalTranscript."""
    log_path = Path(path)
    if not log_path.exists():
        raise FileNotFoundError(f"Log file not found: {path}")

    events: list[dict] = []
    for line in log_path.read_text().splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            events.append(json.loads(line))
        except (json.JSONDecodeError, ValueError):
            continue

    # Collect tool_use items, tool_result items, and text blocks
    pending_uses: dict[str, dict] = {}
    results_by_id: dict[str, Any] = {}
    use_order: list[str] = []
    text_blocks: list[str] = []

    session_id = ""
    model = ""
    total_cost_usd = 0.0
    num_turns = 0
    duration_ms = 0
    stop_reason = ""
    assistant_message_count = 0

    for ev in events:
        ev_type = ev.get("type", "")

        if ev_type == "assistant":
            assistant_message_count += 1
            msg = ev.get("message", ev)
            content = msg.get("content", [])
            if isinstance(content, list):
                for block in content:
                    if not isinstance(block, dict):
                        continue
                    block_type = block.get("type", "")
                    if block_type == "tool_use":
                        uid = block.get("id", "")
                        if uid:
                            pending_uses[uid] = {
                                "name": block.get("name", ""),
                                "input": block.get("input", {}),
                            }
                            use_order.append(uid)
                    elif block_type == "text":
                        txt = block.get("text", "").strip()
                        if txt:
                            text_blocks.append(txt)

        elif ev_type == "content_block_start":
            cb = ev.get("content_block", {})
            if cb.get("type") == "tool_use":
                uid = cb.get("id", "")
                if uid and uid not in pending_uses:
                    pending_uses[uid] = {
                        "name": cb.get("name", ""),
                        "input": cb.get("input", {}),
                    }
                    use_order.append(uid)

        elif ev_type == "tool_result":
            uid = ev.get("tool_use_id", "")
            if uid:
                results_by_id[uid] = ev

        elif ev_type == "result":
            session_id = ev.get("session_id", session_id)
            model = ev.get("model", model)
            total_cost_usd = ev.get("total_cost_usd", 0.0) or ev.get("cost_usd", 0.0)
            num_turns = ev.get("num_turns", 0)
            duration_ms = ev.get("duration_ms", 0)
            stop_reason = ev.get("stop_reason", ev.get("reason", ""))

        elif ev_type == "system" and ev.get("subtype") == "init":
            session_id = ev.get("session_id", session_id)
            model = ev.get("model", model)

    # Build ToolCall list
    seen_files: set[str] = set()
    raw_calls: list[dict] = []

    for idx, uid in enumerate(use_order):
        use_info = pending_uses.get(uid, {"name": "", "input": {}})
        tool_name = use_info["name"]
        tool_input = use_info["input"]

        result_ev = results_by_id.get(uid, {})
        response_content = result_ev.get("content", result_ev.get("output", ""))

        full_text = _stringify_content(response_content)
        response_bytes = len(full_text.encode("utf-8", errors="replace"))
        truncated = full_text[:RESPONSE_TRUNCATE]

        is_error = result_ev.get("is_error", False) or _response_is_error(response_content)
        pepper_cmd = _extract_pepper_command(tool_name, tool_input)

        is_reread = False
        if tool_name == "Read":
            fp = tool_input.get("file_path", "")
            if fp in seen_files:
                is_reread = True
            else:
                seen_files.add(fp)

        raw_calls.append({
            "index": idx,
            "tool_name": tool_name,
            "tool_input": tool_input,
            "response_text": truncated,
            "is_error": is_error,
            "response_bytes": response_bytes,
            "pepper_command": pepper_cmd,
            "is_reread": is_reread,
            "is_wasted": False,
        })

    # Mark wasted calls (error + identical retry)
    for i in range(len(raw_calls) - 1):
        cur = raw_calls[i]
        nxt = raw_calls[i + 1]
        if cur["is_error"] and cur["tool_name"] == nxt["tool_name"] and cur["tool_input"] == nxt["tool_input"]:
            cur["is_wasted"] = True

    tool_calls = [ToolCall(**rc) for rc in raw_calls]

    # Derive turn count from assistant messages if result event didn't provide it
    if num_turns == 0 and assistant_message_count > 0:
        num_turns = assistant_message_count

    return EvalTranscript(
        session_id=session_id,
        model=model,
        tool_calls=tool_calls,
        text_blocks=text_blocks,
        total_cost_usd=total_cost_usd,
        num_turns=num_turns,
        duration_ms=duration_ms,
        stop_reason=stop_reason,
    )


def _print_summary(transcript: EvalTranscript) -> None:
    print(f"Session:  {transcript.session_id or '(unknown)'}")
    print(f"Model:    {transcript.model or '(unknown)'}")
    print(f"Turns:    {transcript.num_turns}")
    print(f"Duration: {transcript.duration_ms}ms")
    print(f"Cost:     ${transcript.total_cost_usd:.4f}")
    print(f"Stop:     {transcript.stop_reason or '(unknown)'}")
    print()
    print(f"Tool calls: {len(transcript.tool_calls)}")
    print(f"  Errors:  {transcript.error_count}")
    print(f"  Rereads: {transcript.reread_count}")
    print(f"  Wasted:  {transcript.wasted_call_count}")
    print()

    if transcript.tool_counts:
        print("Tool breakdown:")
        for name, count in sorted(transcript.tool_counts.items(), key=lambda x: -x[1]):
            print(f"  {name}: {count}")
        print()

    if transcript.pepper_tool_counts:
        print("Pepper commands:")
        for name, count in sorted(transcript.pepper_tool_counts.items(), key=lambda x: -x[1]):
            print(f"  {name}: {count}")
        print()

    rereads = {fp: n for fp, n in transcript.files_read.items() if n > 1}
    if rereads:
        print("Files read multiple times:")
        for fp, n in sorted(rereads.items(), key=lambda x: -x[1]):
            print(f"  {fp}: {n}x")
        print()

    print(f"Text blocks: {len(transcript.text_blocks)}")


def main() -> None:
    parser = argparse.ArgumentParser(description="Parse Claude CLI verbose log.")
    parser.add_argument("--log", required=True, help="Path to verbose stream-json log")
    parser.add_argument("--json", action="store_true", help="Output full transcript as JSON")
    args = parser.parse_args()

    transcript = parse_verbose_log(args.log)

    if args.json:
        print(json.dumps(transcript.to_dict(), indent=2))
    else:
        _print_summary(transcript)


if __name__ == "__main__":
    main()

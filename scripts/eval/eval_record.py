#!/usr/bin/env python3
"""Record MCP tool calls from a verbose log into a replay fixture.

Extracts every MCP tool call and its response from a completed eval run's
verbose log. The output is a JSONL file usable by eval_replay.py.

Usage:
    python3 scripts/eval/eval_record.py --log build/logs/verbose-bugfix-123.log --output eval/fixtures/recording.jsonl
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from eval_transcript import parse_verbose_log


def extract_recordings(log_path: str) -> list[dict]:
    transcript = parse_verbose_log(log_path)
    recordings = []

    for i, tc in enumerate(transcript.tool_calls):
        if tc.pepper_command or tc.tool_name == "Bash":
            recordings.append({
                "seq": i,
                "tool": f"mcp__pepper__{tc.pepper_command}" if tc.pepper_command else tc.tool_name,
                "input": tc.tool_input,
                "response": tc.response_text,
                "is_error": tc.is_error,
                "response_bytes": tc.response_bytes,
            })

    return recordings


def write_fixture(recordings: list[dict], output_path: str) -> None:
    out = Path(output_path)
    out.parent.mkdir(parents=True, exist_ok=True)
    with open(out, "w") as f:
        for rec in recordings:
            f.write(json.dumps(rec) + "\n")
    print(f"Recorded {len(recordings)} tool calls to {output_path}")


def main() -> None:
    parser = argparse.ArgumentParser(description="Record MCP calls for replay.")
    parser.add_argument("--log", required=True, help="Path to verbose log file")
    parser.add_argument("--output", required=True, help="Output JSONL file path")
    args = parser.parse_args()

    recordings = extract_recordings(args.log)
    if not recordings:
        print("No MCP or Bash tool calls found in log.", file=sys.stderr)
        sys.exit(1)

    write_fixture(recordings, args.output)


if __name__ == "__main__":
    main()

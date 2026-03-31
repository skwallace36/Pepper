#!/usr/bin/env python3
"""Orchestrate a single eval run: setup -> launch agent -> capture -> score.

Usage:
    python3 scripts/eval/eval_run.py --task eval/tasks/navigation/reach-detail-screen.yaml
    python3 scripts/eval/eval_run.py --task eval/tasks/nav.yaml --prompt eval/prompts/v2.md
    python3 scripts/eval/eval_run.py --task eval/tasks/nav.yaml --mode replay --fixture eval/fixtures/nav/recording.jsonl
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from eval_score import compute_score, print_score
from eval_transcript import parse_verbose_log


def _git_sha() -> str:
    try:
        return subprocess.check_output(
            ["git", "rev-parse", "HEAD"], stderr=subprocess.DEVNULL, text=True
        ).strip()
    except Exception:
        return ""


def _git_branch() -> str:
    try:
        return subprocess.check_output(
            ["git", "branch", "--show-current"], stderr=subprocess.DEVNULL, text=True
        ).strip()
    except Exception:
        return ""


def _file_hash(path: str) -> str:
    try:
        content = Path(path).resolve().read_bytes()
        return hashlib.sha256(content).hexdigest()[:16]
    except Exception:
        return ""


SELF_REPORT_SUFFIX = """
## Eval Self-Report (REQUIRED)
When your task is complete, output exactly this block:
<eval-self-report>
{"confidence": 0-10, "blockers": ["any blockers encountered"], "tool_issues": ["tools that didn't work as expected"], "prompt_clarity": 0-10, "prompt_gaps": ["what was missing from instructions"], "wasted_effort": ["where you spent time unproductively"], "suggestions": ["how the prompt could be improved"]}
</eval-self-report>
"""


def _load_task(path: str) -> dict:
    text = Path(path).read_text()
    try:
        import yaml
        return yaml.safe_load(text)
    except ImportError:
        return json.loads(text)


def _build_system_prompt(prompt_file: str | None) -> str:
    """Build the system prompt (stable across tasks — maximizes prompt caching)."""
    parts = []
    if prompt_file:
        parts.append(Path(prompt_file).read_text())
    parts.append(SELF_REPORT_SUFFIX)
    return "\n".join(parts)


def _build_user_prompt(task: dict) -> str:
    """Build the user message (varies per task — not cached)."""
    goal = task.get("goal", "")
    return f"Complete the following task.\n\n{goal}" if goal else "Complete the task."


def _build_mcp_config(mode: str, fixture: str | None) -> str | None:
    if mode != "replay":
        return None
    if not fixture:
        print("Error: --fixture required for replay mode", file=sys.stderr)
        sys.exit(1)

    repo_root = Path(__file__).resolve().parent.parent.parent
    config = {
        "mcpServers": {
            "pepper": {
                "command": sys.executable,
                "args": [
                    str(repo_root / "scripts" / "eval" / "eval_replay.py"),
                    "--fixture", str(Path(fixture).resolve()),
                    "--serve",
                ],
                "env": {"PYTHONUNBUFFERED": "1"},
            }
        }
    }
    fd, path = tempfile.mkstemp(suffix=".json", prefix="eval-mcp-")
    with os.fdopen(fd, "w") as f:
        json.dump(config, f, indent=2)
    return path


def run_eval(
    task_path: str,
    prompt_file: str | None = None,
    output_dir: str | None = None,
    mode: str = "live",
    fixture: str | None = None,
    model: str = "haiku",
) -> dict:
    task = _load_task(task_path)

    if not output_dir:
        ts = int(time.time())
        output_dir = f"eval/results/{ts}"
    out = Path(output_dir)
    out.mkdir(parents=True, exist_ok=True)

    # Split prompt: system prompt (stable, cached) + user message (varies per task)
    system_prompt = _build_system_prompt(prompt_file)
    user_prompt = _build_user_prompt(task)
    budget = task.get("budget_usd", 2.00)
    timeout = task.get("timeout_s", 300)

    # Replay mode is cheaper — tighten budget automatically
    if mode == "replay":
        budget = min(budget, 0.50)

    verbose_log = out / "verbose.log"
    manifest = {
        "task": task_path,
        "task_name": task.get("name", ""),
        "prompt_file": prompt_file,
        "mode": mode,
        "model": model,
        "budget_usd": budget,
        "timeout_s": timeout,
        "started_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }

    # System prompt goes in --append-system-prompt (cached across runs with same variant).
    # Task goal goes in -p user message (varies per task, not cached).
    cmd = [
        "claude", "-p", user_prompt,
        "--append-system-prompt", system_prompt,
        "--model", model,
        "--max-budget-usd", str(budget),
        "--output-format", "stream-json",
        "--verbose",
    ]

    mcp_config = _build_mcp_config(mode, fixture)
    if mcp_config:
        cmd.extend(["--mcp-config", mcp_config, "--strict-mcp-config"])

    print(f"Running eval: {task.get('name', task_path)}")
    print(f"  Mode: {mode}, Model: {model}, Budget: ${budget}, Timeout: {timeout}s")
    print(f"  Output: {out}")

    try:
        with open(verbose_log, "w") as log_f:
            proc = subprocess.Popen(
                cmd,
                stdout=log_f,
                stderr=subprocess.STDOUT,
                preexec_fn=os.setsid,
            )
            try:
                proc.wait(timeout=timeout)
            except subprocess.TimeoutExpired:
                os.killpg(os.getpgid(proc.pid), signal.SIGTERM)
                proc.wait(timeout=10)
                manifest["timed_out"] = True
                print(f"  Timed out after {timeout}s")
    except FileNotFoundError:
        print("Error: 'claude' CLI not found. Install Claude Code first.", file=sys.stderr)
        sys.exit(1)
    finally:
        if mcp_config:
            os.unlink(mcp_config)

    manifest["finished_at"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())

    try:
        transcript = parse_verbose_log(str(verbose_log))
        score = compute_score(transcript, task)
        score_dict = score.to_dict()
        (out / "score.json").write_text(json.dumps(score_dict, indent=2) + "\n")
        (out / "transcript.json").write_text(json.dumps(transcript.to_dict(), indent=2) + "\n")

        # Enrich manifest with post-run metadata
        manifest["model_id"] = transcript.model or model
        manifest["duration_ms"] = transcript.duration_ms
        manifest["git_sha"] = _git_sha()
        manifest["git_branch"] = _git_branch()
        if prompt_file:
            manifest["prompt_hash"] = _file_hash(prompt_file)
        (out / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")

        print_score(score, transcript)
        return score_dict
    except Exception as e:
        print(f"  Scoring failed: {e}", file=sys.stderr)
        return {"error": str(e)}


def main() -> None:
    parser = argparse.ArgumentParser(description="Run a single eval.")
    parser.add_argument("--task", required=True, help="Path to task YAML")
    parser.add_argument("--prompt", help="Path to prompt variant file")
    parser.add_argument("--output", help="Output directory for results")
    parser.add_argument("--mode", choices=["live", "replay"], default="live")
    parser.add_argument("--fixture", help="Recording fixture for replay mode")
    parser.add_argument("--model", default="haiku", help="Model to use (default: haiku for cost efficiency)")
    args = parser.parse_args()

    run_eval(
        task_path=args.task,
        prompt_file=args.prompt,
        output_dir=args.output,
        mode=args.mode,
        fixture=args.fixture,
        model=args.model,
    )


if __name__ == "__main__":
    main()

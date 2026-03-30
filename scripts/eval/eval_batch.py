#!/usr/bin/env python3
"""Run eval task x prompt variant matrix with repetitions.

Usage:
    python3 scripts/eval/eval_batch.py --tasks eval/tasks/navigation/ --prompts eval/prompts/mcp-instructions/
    python3 scripts/eval/eval_batch.py --tasks eval/tasks/ --prompts eval/prompts/ --runs 3 --mode replay
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
from pathlib import Path
from statistics import mean, stdev

sys.path.insert(0, str(Path(__file__).parent))
from eval_run import run_eval


def discover_files(directory: str, extensions: set[str]) -> list[str]:
    results = []
    for root, _, files in os.walk(directory):
        for f in files:
            if Path(f).suffix in extensions:
                results.append(os.path.join(root, f))
    return sorted(results)


def run_batch(
    tasks_dir: str,
    prompts_dir: str,
    runs: int = 1,
    mode: str = "live",
    fixture_dir: str | None = None,
    model: str = "sonnet",
    output_dir: str | None = None,
) -> dict:
    tasks = discover_files(tasks_dir, {".yaml", ".yml"})
    prompts = discover_files(prompts_dir, {".md"})

    if not tasks:
        print(f"No task files found in {tasks_dir}", file=sys.stderr)
        sys.exit(1)
    if not prompts:
        prompts = [None]

    if not output_dir:
        output_dir = f"eval/results/batch-{time.strftime('%Y%m%d-%H%M%S')}"

    out = Path(output_dir)
    out.mkdir(parents=True, exist_ok=True)

    print(f"Batch eval: {len(tasks)} tasks x {len(prompts)} prompts x {runs} runs")
    print(f"Output: {out}\n")

    all_results = []
    combo_scores: dict[str, list[dict]] = {}

    for task_path in tasks:
        for prompt_path in prompts:
            task_name = Path(task_path).stem
            prompt_name = Path(prompt_path).stem if prompt_path else "no-prompt"
            combo_key = f"{task_name}|{prompt_name}"
            combo_scores[combo_key] = []

            for run_idx in range(runs):
                run_dir = out / task_name / prompt_name / f"run-{run_idx}"

                fixture = None
                if mode == "replay" and fixture_dir:
                    fixture_file = Path(fixture_dir) / task_name / "recording.jsonl"
                    if fixture_file.exists():
                        fixture = str(fixture_file)

                print(f"--- {task_name} x {prompt_name} (run {run_idx + 1}/{runs}) ---")

                try:
                    score = run_eval(
                        task_path=task_path,
                        prompt_file=prompt_path,
                        output_dir=str(run_dir),
                        mode=mode,
                        fixture=fixture,
                        model=model,
                    )
                    combo_scores[combo_key].append(score)
                    all_results.append({
                        "task": task_path,
                        "prompt": prompt_path,
                        "run": run_idx,
                        "score": score,
                    })
                except Exception as e:
                    print(f"  Error: {e}", file=sys.stderr)
                    all_results.append({
                        "task": task_path,
                        "prompt": prompt_path,
                        "run": run_idx,
                        "error": str(e),
                    })

    summary = _build_summary(combo_scores)
    summary["total_runs"] = len(all_results)
    summary["successful_runs"] = sum(1 for r in all_results if "score" in r)
    summary["failed_runs"] = sum(1 for r in all_results if "error" in r)

    (out / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    (out / "all_results.json").write_text(json.dumps(all_results, indent=2) + "\n")

    _print_summary(summary)
    print(f"\nSummary written to {out / 'summary.json'}")
    return summary


def _build_summary(combo_scores: dict[str, list[dict]]) -> dict:
    combos = {}
    for key, scores in combo_scores.items():
        valid = [s for s in scores if "error" not in s]
        if not valid:
            combos[key] = {"runs": len(scores), "valid": 0}
            continue

        composites = [s.get("composite_score", 0) for s in valid]
        lba = [s.get("look_before_act", 0) for s in valid]
        costs = [s.get("cost_usd", 0) for s in valid]
        tool_counts = [s.get("tool_call_count", 0) for s in valid]

        combos[key] = {
            "runs": len(scores),
            "valid": len(valid),
            "composite_mean": round(mean(composites), 1),
            "composite_stdev": round(stdev(composites), 1) if len(composites) > 1 else 0,
            "look_before_act_mean": round(mean(lba), 2),
            "cost_mean": round(mean(costs), 4),
            "tool_calls_mean": round(mean(tool_counts), 1),
        }

    return {"combos": combos}


def _print_summary(summary: dict) -> None:
    print(f"\n{'='*70}")
    print(f"  Batch Summary: {summary['successful_runs']}/{summary['total_runs']} runs succeeded")
    print(f"{'='*70}\n")

    print(f"  {'Task|Prompt':<40} {'Score':>8} {'+/-':>6} {'LBA':>6} {'Cost':>8} {'Calls':>6}")
    print(f"  {'-'*66}")

    for key, stats in summary.get("combos", {}).items():
        if stats.get("valid", 0) == 0:
            print(f"  {key:<40} {'FAILED':>8}")
            continue
        print(
            f"  {key:<40} "
            f"{stats['composite_mean']:>7.1f} "
            f"{stats.get('composite_stdev', 0):>5.1f} "
            f"{stats['look_before_act_mean']:>5.2f} "
            f"${stats['cost_mean']:>6.4f} "
            f"{stats['tool_calls_mean']:>5.1f}"
        )


def main() -> None:
    parser = argparse.ArgumentParser(description="Batch eval runner.")
    parser.add_argument("--tasks", required=True, help="Directory of task YAML files")
    parser.add_argument("--prompts", required=True, help="Directory of prompt variant files")
    parser.add_argument("--runs", type=int, default=1, help="Runs per combination")
    parser.add_argument("--mode", choices=["live", "replay"], default="live")
    parser.add_argument("--fixtures", help="Fixture directory for replay mode")
    parser.add_argument("--model", default="haiku", help="Model (default: haiku for cost efficiency)")
    parser.add_argument("--output", help="Output directory")
    args = parser.parse_args()

    run_batch(
        tasks_dir=args.tasks,
        prompts_dir=args.prompts,
        runs=args.runs,
        mode=args.mode,
        fixture_dir=args.fixtures,
        model=args.model,
        output_dir=args.output,
    )


if __name__ == "__main__":
    main()

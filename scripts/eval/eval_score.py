#!/usr/bin/env python3
"""Score an agent run based on transcript analysis and optional task criteria.

Computes tool-usage quality, efficiency, and task success metrics from a
parsed verbose log. Outputs a score.json and prints a human-readable summary.

Usage:
    python3 scripts/eval/eval_score.py --log path/to/verbose.log
    python3 scripts/eval/eval_score.py --log path/to/verbose.log --task eval/tasks/nav.yaml
    python3 scripts/eval/eval_score.py --log path/to/verbose.log --output score.json
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from eval_transcript import EvalTranscript, parse_verbose_log

ACTION_TOOLS = {"tap", "scroll", "scroll_to", "swipe", "input_text", "toggle", "gesture"}
OBSERVE_TOOLS = {"look", "find", "tree", "read_element", "screen", "snapshot"}


# ─── Metric Calculators ─────────────────────────────────────────────


def calc_look_before_act(transcript: EvalTranscript) -> float:
    """Ratio of action calls preceded by a look within the last 3 tool calls."""
    action_count = 0
    preceded_count = 0

    for i, tc in enumerate(transcript.tool_calls):
        if tc.pepper_command not in ACTION_TOOLS:
            continue
        action_count += 1
        start = max(0, i - 3)
        for j in range(start, i):
            if transcript.tool_calls[j].pepper_command in OBSERVE_TOOLS:
                preceded_count += 1
                break

    if action_count == 0:
        return 1.0
    return preceded_count / action_count


def calc_consecutive_actions(transcript: EvalTranscript) -> int:
    """Count sequences of 2+ action tools without an intervening observe tool."""
    streak = 0
    violations = 0

    for tc in transcript.tool_calls:
        if tc.pepper_command in ACTION_TOOLS:
            streak += 1
            if streak >= 2:
                violations += 1
        elif tc.pepper_command in OBSERVE_TOOLS:
            streak = 0

    return violations


def calc_error_recovery(transcript: EvalTranscript) -> float:
    """After errors, ratio of adapted retries vs blind retries."""
    adapted = 0
    blind = 0

    for i in range(len(transcript.tool_calls) - 1):
        cur = transcript.tool_calls[i]
        nxt = transcript.tool_calls[i + 1]
        if not cur.is_error:
            continue
        if cur.tool_name == nxt.tool_name and cur.tool_input == nxt.tool_input:
            blind += 1
        else:
            adapted += 1

    total = adapted + blind
    if total == 0:
        return 1.0
    return adapted / total


def calc_pepper_diversity(transcript: EvalTranscript) -> int:
    return len(transcript.pepper_tool_counts)


def extract_self_report(transcript: EvalTranscript) -> dict | None:
    for text in transcript.text_blocks:
        match = re.search(
            r"<eval-self-report>\s*(\{.*?\})\s*</eval-self-report>",
            text,
            re.DOTALL,
        )
        if match:
            try:
                return json.loads(match.group(1))
            except json.JSONDecodeError:
                continue
    return None


# ─── Task Evaluation ─────────────────────────────────────────────────


def _load_task(path: str) -> dict:
    text = Path(path).read_text()
    try:
        import yaml
        return yaml.safe_load(text)
    except ImportError:
        return json.loads(text)


def check_task_success(transcript: EvalTranscript, task: dict) -> dict[str, bool]:
    results: dict[str, bool] = {}
    success = task.get("success", {})

    required_tools = success.get("pepper_tools_called", [])
    if required_tools:
        used = set(transcript.pepper_tool_counts.keys())
        results["pepper_tools_called"] = all(t in used for t in required_tools)

    min_looks = success.get("min_look_calls")
    if min_looks is not None:
        results["min_look_calls"] = transcript.pepper_tool_counts.get("look", 0) >= min_looks

    required_output = success.get("output_contains", [])
    if required_output:
        all_text = " ".join(transcript.text_blocks).lower()
        results["output_contains"] = all(s.lower() in all_text for s in required_output)

    if "pr_opened" in success:
        has_pr = any(
            "gh pr create" in tc.tool_input.get("command", "")
            for tc in transcript.tool_calls
            if tc.tool_name == "Bash"
        )
        results["pr_opened"] = has_pr == success["pr_opened"]

    diff_strings = success.get("diff_contains", [])
    if diff_strings:
        diff_text = ""
        for tc in transcript.tool_calls:
            if tc.tool_name == "Bash" and "git diff" in tc.tool_input.get("command", ""):
                diff_text += tc.response_text
        results["diff_contains"] = all(s in diff_text for s in diff_strings)

    return results


def check_anti_patterns(
    transcript: EvalTranscript,
    task: dict,
    metrics: dict[str, float | int],
) -> list[str]:
    violations = []
    for ap in task.get("anti_patterns", []):
        rule = ap.get("rule")
        if not rule:
            continue
        match = re.match(r"(\w+)\s*([<>]=?)\s*([\d.]+)", rule)
        if not match:
            continue
        metric_name, op, threshold_str = match.groups()
        threshold = float(threshold_str)
        value = metrics.get(metric_name)
        if value is None:
            continue
        violated = False
        if op == "<" and not (value < threshold):
            violated = True
        elif op == "<=" and not (value <= threshold):
            violated = True
        elif op == ">" and not (value > threshold):
            violated = True
        elif op == ">=" and not (value >= threshold):
            violated = True
        if violated:
            violations.append(ap["name"])
    return violations


# ─── Score Computation ───────────────────────────────────────────────


@dataclass
class EvalScore:
    look_before_act: float
    consecutive_actions: int
    error_recovery: float
    pepper_tool_diversity: int
    turn_count: int
    cost_usd: float
    tool_call_count: int
    wasted_calls: int
    reread_ratio: float
    task_success: dict[str, bool] | None = None
    anti_pattern_violations: list[str] = field(default_factory=list)
    self_report: dict | None = None
    composite_score: float = 0.0

    def to_dict(self) -> dict:
        return {
            "look_before_act": self.look_before_act,
            "consecutive_actions": self.consecutive_actions,
            "error_recovery": self.error_recovery,
            "pepper_tool_diversity": self.pepper_tool_diversity,
            "turn_count": self.turn_count,
            "cost_usd": self.cost_usd,
            "tool_call_count": self.tool_call_count,
            "wasted_calls": self.wasted_calls,
            "reread_ratio": self.reread_ratio,
            "task_success": self.task_success,
            "anti_pattern_violations": self.anti_pattern_violations,
            "self_report": self.self_report,
            "composite_score": self.composite_score,
        }


def _normalize(metric: str, value: float | int, budget: float | None = None) -> float:
    norms: dict[str, Any] = {
        "look_before_act": lambda v: v * 100,
        "consecutive_actions": lambda v: max(0, 100 - v * 20),
        "error_recovery": lambda v: v * 100,
        "pepper_tool_diversity": lambda v: min(100, v * 10),
        "wasted_calls": lambda v: max(0, 100 - v * 15),
        "reread_ratio": lambda v: (1 - v) * 100,
    }
    if metric == "cost_usd" and budget:
        return max(0, 100 - (value / budget * 100))
    if metric in norms:
        return norms[metric](value)
    return 50.0


from typing import Any


def compute_score(
    transcript: EvalTranscript,
    task: dict | None = None,
) -> EvalScore:
    lba = calc_look_before_act(transcript)
    ca = calc_consecutive_actions(transcript)
    er = calc_error_recovery(transcript)
    pd = calc_pepper_diversity(transcript)

    total_reads = sum(transcript.files_read.values()) if transcript.files_read else 0
    reread_ratio = transcript.reread_count / max(1, total_reads)

    raw_metrics: dict[str, float | int] = {
        "look_before_act": lba,
        "consecutive_actions": ca,
        "error_recovery": er,
        "pepper_tool_diversity": pd,
        "tool_call_count": len(transcript.tool_calls),
        "wasted_calls": transcript.wasted_call_count,
        "reread_ratio": reread_ratio,
    }

    task_success = None
    anti_violations: list[str] = []
    budget = None

    if task:
        task_success = check_task_success(transcript, task)
        anti_violations = check_anti_patterns(transcript, task, raw_metrics)
        budget = task.get("budget_usd")

    n_lba = _normalize("look_before_act", lba)
    n_ca = _normalize("consecutive_actions", ca)
    n_er = _normalize("error_recovery", er)
    n_pd = _normalize("pepper_tool_diversity", pd)
    n_wc = _normalize("wasted_calls", transcript.wasted_call_count)
    n_rr = _normalize("reread_ratio", reread_ratio)
    n_cost = _normalize("cost_usd", transcript.total_cost_usd, budget)

    if task:
        weights = task.get("weights", {})
        w_success = weights.get("success", 0.35)
        w_efficiency = weights.get("efficiency", 0.25)
        w_tool = weights.get("tool_usage", 0.25)
        w_compliance = weights.get("compliance", 0.15)

        if task_success:
            passed = sum(1 for v in task_success.values() if v)
            success_score = (passed / max(1, len(task_success))) * 100
        else:
            success_score = 50.0

        tool_score = (n_lba + n_ca + n_er + n_pd) / 4
        efficiency_score = (n_wc + n_rr + n_cost) / 3
        compliance_score = max(0, 100 - len(anti_violations) * 25)

        composite = (
            success_score * w_success
            + efficiency_score * w_efficiency
            + tool_score * w_tool
            + compliance_score * w_compliance
        )
    else:
        tool_score = (n_lba + n_ca + n_er + n_pd) / 4
        efficiency_score = (n_wc + n_rr + n_cost) / 3
        composite = tool_score * 0.40 + efficiency_score * 0.60

    return EvalScore(
        look_before_act=lba,
        consecutive_actions=ca,
        error_recovery=er,
        pepper_tool_diversity=pd,
        turn_count=transcript.num_turns,
        cost_usd=transcript.total_cost_usd,
        tool_call_count=len(transcript.tool_calls),
        wasted_calls=transcript.wasted_call_count,
        reread_ratio=reread_ratio,
        task_success=task_success,
        anti_pattern_violations=anti_violations,
        self_report=extract_self_report(transcript),
        composite_score=round(composite, 1),
    )


# ─── Display ─────────────────────────────────────────────────────────

BOLD = "\033[1m"
DIM = "\033[2m"
RED = "\033[31m"
GREEN = "\033[32m"
YELLOW = "\033[33m"
NC = "\033[0m"


def _color_score(value: float) -> str:
    if value >= 70:
        return GREEN
    if value >= 40:
        return YELLOW
    return RED


def _bar(value: float, width: int = 10) -> str:
    filled = int(value / 100 * width)
    return "\u2588" * filled + "\u2591" * (width - filled)


def print_score(score: EvalScore, transcript: EvalTranscript) -> None:
    sid = transcript.session_id or "(unknown)"
    print(f"\n{BOLD}=== Eval Score: {sid} ==={NC}\n")

    print(f"{BOLD}Tool Usage{NC}")
    for name, raw, norm in [
        ("look_before_act", score.look_before_act, _normalize("look_before_act", score.look_before_act)),
        ("consecutive_actions", score.consecutive_actions, _normalize("consecutive_actions", score.consecutive_actions)),
        ("error_recovery", score.error_recovery, _normalize("error_recovery", score.error_recovery)),
        ("pepper_diversity", score.pepper_tool_diversity, _normalize("pepper_tool_diversity", score.pepper_tool_diversity)),
    ]:
        c = _color_score(norm)
        print(f"  {name:<24} {c}{_bar(norm)}{NC}  {raw:<6}  ({norm:.0f})")

    print(f"\n{BOLD}Efficiency{NC}")
    print(f"  turns               {score.turn_count}")
    print(f"  cost                ${score.cost_usd:.4f}")
    print(f"  tool_calls          {score.tool_call_count}")
    print(f"  wasted              {score.wasted_calls}")
    print(f"  reread_ratio        {score.reread_ratio:.2f}")

    if score.task_success:
        print(f"\n{BOLD}Task Success{NC}")
        for criterion, passed in score.task_success.items():
            mark = f"{GREEN}pass{NC}" if passed else f"{RED}FAIL{NC}"
            print(f"  {mark} {criterion}")

    if score.anti_pattern_violations:
        print(f"\n{BOLD}Anti-Pattern Violations{NC}")
        for v in score.anti_pattern_violations:
            print(f"  {RED}!{NC} {v}")

    if score.self_report:
        print(f"\n{BOLD}Self-Report{NC}")
        for key, val in score.self_report.items():
            print(f"  {key}: {val}")

    c = _color_score(score.composite_score)
    print(f"\n{BOLD}Composite: {c}{score.composite_score:.0f}/100{NC}\n")


# ─── CLI ─────────────────────────────────────────────────────────────


def main() -> None:
    parser = argparse.ArgumentParser(description="Score an agent eval run.")
    parser.add_argument("--log", required=True, help="Path to verbose stream-json log")
    parser.add_argument("--task", help="Path to task YAML definition")
    parser.add_argument("--output", help="Path to write score.json")
    args = parser.parse_args()

    transcript = parse_verbose_log(args.log)
    task = _load_task(args.task) if args.task else None
    score = compute_score(transcript, task)
    print_score(score, transcript)

    if args.output:
        out = Path(args.output)
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(json.dumps(score.to_dict(), indent=2) + "\n")
        print(f"Score written to {args.output}")


if __name__ == "__main__":
    main()

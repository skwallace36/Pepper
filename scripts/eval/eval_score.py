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
        # Rule defines WHEN the anti-pattern fires, e.g. "look_before_act < 1.0"
        # means "violation when look_before_act is below 1.0"
        violated = False
        if op == "<" and value < threshold:
            violated = True
        elif op == "<=" and value <= threshold:
            violated = True
        elif op == ">" and value > threshold:
            violated = True
        elif op == ">=" and value >= threshold:
            violated = True
        if violated:
            violations.append(ap["name"])
    return violations


# ─── Score Computation ───────────────────────────────────────────────


@dataclass
class EvalScore:
    # Tool quality metrics (prompt-dependent — "how well did the agent use tools?")
    look_before_act: float
    consecutive_actions: int
    error_recovery: float
    pepper_tool_diversity: int
    wasted_calls: int
    reread_ratio: float
    # Efficiency metrics
    turn_count: int
    cost_usd: float
    tool_call_count: int
    # Task completion (infrastructure-dependent — "did the agent finish?")
    task_success: dict[str, bool] | None = None
    anti_pattern_violations: list[str] = field(default_factory=list)
    # Qualitative
    self_report: dict | None = None
    # Two independent scores (0-100)
    tool_quality_score: float = 0.0       # Prompt-dependent: how well tools were used
    completion_score: float = 0.0         # Infrastructure-dependent: did it finish the task
    efficiency_score: float = 0.0         # Cost and speed
    composite_score: float = 0.0          # Weighted blend (kept for backwards compat)

    def to_dict(self) -> dict:
        return {
            "schema_version": 2,
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
            "tool_quality_score": self.tool_quality_score,
            "completion_score": self.completion_score,
            "efficiency_score": self.efficiency_score,
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

    # ── Tool Quality Score (prompt-dependent) ──
    # Measures HOW WELL the agent used tools, independent of whether it finished.
    # This is what prompt changes should move.
    tool_score = (n_lba + n_ca + n_er + n_pd) / 4

    # ── Efficiency Score ──
    # Cost, speed, waste. Affected by both prompt and infrastructure.
    # In replay mode (cost=0), exclude cost from efficiency — it's not meaningful.
    if transcript.total_cost_usd == 0:
        eff_score = (n_wc + n_rr) / 2
    else:
        eff_score = (n_wc + n_rr + n_cost) / 3

    # ── Completion Score (infrastructure-dependent) ──
    # Did the agent achieve the goal? Affected by auth, sim health, timeouts.
    if task and task_success:
        passed = sum(1 for v in task_success.values() if v)
        comp_score = (passed / max(1, len(task_success))) * 100
    else:
        # No task criteria — use a heuristic: did the agent produce output?
        has_output = len(transcript.text_blocks) > 0
        has_commits = any(
            "git commit" in tc.tool_input.get("command", "")
            for tc in transcript.tool_calls
            if tc.tool_name == "Bash" and not tc.is_error
        )
        has_pr = any(
            "gh pr create" in tc.tool_input.get("command", "")
            for tc in transcript.tool_calls
            if tc.tool_name == "Bash" and not tc.is_error
        )
        comp_score = 50.0  # baseline
        if has_output:
            comp_score += 20
        if has_commits:
            comp_score += 15
        if has_pr:
            comp_score += 15

    # ── Composite (backwards-compatible blend) ──
    compliance_score = max(0, 100 - len(anti_violations) * 25)
    composite = tool_score * 0.35 + eff_score * 0.25 + comp_score * 0.25 + compliance_score * 0.15

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
        tool_quality_score=round(tool_score, 1),
        completion_score=round(comp_score, 1),
        efficiency_score=round(eff_score, 1),
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

    # Split scores
    print(f"\n{BOLD}Scores{NC}")
    tq = score.tool_quality_score
    cs = score.completion_score
    es = score.efficiency_score
    print(f"  Tool Quality  {_color_score(tq)}{_bar(tq)}{NC}  {tq:.0f}/100  (prompt-dependent)")
    print(f"  Completion    {_color_score(cs)}{_bar(cs)}{NC}  {cs:.0f}/100  (infra-dependent)")
    print(f"  Efficiency    {_color_score(es)}{_bar(es)}{NC}  {es:.0f}/100")
    c = _color_score(score.composite_score)
    print(f"  {BOLD}Composite   {c}{_bar(score.composite_score)}{NC}  {score.composite_score:.0f}/100{NC}\n")


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

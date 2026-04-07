"""pepper test runner -- deterministic UI test flows via Pepper commands.

Runs sequential test steps (tap, scroll, verify, etc.) against a running
Pepper instance. No LLM, no AI -- just command sequences like a real user.

Test files are YAML with sugar shortcuts for common Pepper commands.
See scripts/sample-flow.yaml for the format.
"""

from __future__ import annotations

import argparse
import json
import signal
import subprocess
import sys
import time
import xml.etree.ElementTree as ET
from dataclasses import dataclass, field
from pathlib import Path

try:
    import yaml
except ImportError:
    print("Error: pyyaml required. Install with: pip install pyyaml", file=sys.stderr)
    sys.exit(2)

from .pepper_ax import find_and_dismiss_dialog
from .pepper_common import DEFAULT_HOST, discover_port
from .pepper_websocket import CrashError, make_command, send_command_sync

# ---------------------------------------------------------------------------
# Result types
# ---------------------------------------------------------------------------

@dataclass
class StepResult:
    name: str
    status: str  # "pass", "fail", "error"
    elapsed: float = 0.0
    message: str = ""
    response: dict = field(default_factory=dict)


@dataclass
class TestResult:
    name: str
    status: str  # "pass", "fail", "error"
    elapsed: float = 0.0
    steps: list[StepResult] = field(default_factory=list)
    message: str = ""


@dataclass
class SuiteResult:
    name: str
    elapsed: float = 0.0
    tests: list[TestResult] = field(default_factory=list)

    @property
    def passed(self) -> int:
        return sum(1 for t in self.tests if t.status == "pass")

    @property
    def failed(self) -> int:
        return sum(1 for t in self.tests if t.status == "fail")

    @property
    def errors(self) -> int:
        return sum(1 for t in self.tests if t.status == "error")

    @property
    def ok(self) -> bool:
        return self.failed == 0 and self.errors == 0


# ---------------------------------------------------------------------------
# Sugar expansion
# ---------------------------------------------------------------------------

def _expand_wait_for(v: dict) -> dict:
    """Expand wait_for sugar — extract timeout to top level as timeout_ms."""
    params: dict = {}
    until = {k: v2 for k, v2 in v.items() if k != "timeout"}
    params["until"] = until
    if "timeout" in v:
        params["timeout_ms"] = v["timeout"]
    return params


def _expand_input(v: str | dict) -> dict:
    """Expand input sugar into Pepper input command params.

    Supports:
      - input: "hello"              → types into focused field
      - input:
          field: "person_name"      → find by accessibility identifier
          value: "Test Person"
      - input:
          id: "email_field"         → alias for field
          value: "test@example.com"
    """
    if isinstance(v, str):
        return {"value": v}
    params: dict = {}
    if "value" in v:
        params["value"] = v["value"]
    elif "text" in v:
        params["value"] = v["text"]
    if "field" in v:
        params["element"] = v["field"]
    elif "id" in v:
        params["element"] = v["id"]
    elif "element" in v:
        params["element"] = v["element"]
    if v.get("clear"):
        params["clear"] = True
    if v.get("submit"):
        params["submit"] = True
    return params


# Sugar keys that map to Pepper commands with shorthand params.
_SUGAR = {
    "tap": lambda v: ("tap", {"text": v} if isinstance(v, str) else
                       {"element": v["id"]} if "id" in v else v),
    "scroll": lambda v: ("scroll", {"direction": v} if isinstance(v, str) else v),
    "swipe": lambda v: ("swipe", v if isinstance(v, dict) else {"direction": v}),
    "input_text": lambda v: ("input", {"element": v["element"], "value": v["text"]}),
    "input": lambda v: ("input", _expand_input(v)),
    "navigate": lambda v: ("navigate", {"screen": v} if isinstance(v, str) else v),
    "back": lambda _v: ("back", {}),
    "dismiss": lambda _v: ("dismiss", {}),
    "dismiss_keyboard": lambda _v: ("dismiss_keyboard", {}),
    "look": lambda _v: ("introspect", {"mode": "map"}),
    "wait_for": lambda v: ("wait_for", {"until": {"text": v}}) if isinstance(v, str) else
                           ("wait_for", _expand_wait_for(v)),
    "wait_idle": lambda _v: ("wait_idle", {}),
    "verify": lambda v: ("verify", v if isinstance(v, dict) else {"text": v}),
    "toggle": lambda v: ("toggle", v if isinstance(v, dict) else {"element": v}),
    "gesture": lambda v: ("gesture", v),
    "dialog": lambda v: ("dialog", v if isinstance(v, dict) else {"action": v}),
    "dismiss_system": lambda _v: ("dismiss_system", {}),
}

# Keys reserved for step options, not Pepper command params.
_STEP_OPTS = {"timeout", "retry", "retry_delay"}


def expand_step(step: dict) -> tuple[str, str | None, dict, dict]:
    """Expand a step dict into (kind, cmd_or_shell, params, opts).

    kind: "pepper" or "shell"
    cmd_or_shell: Pepper command name or shell command string
    params: command params dict (empty for shell)
    opts: step-level overrides (timeout, retry, etc.)
    """
    opts = {k: step[k] for k in _STEP_OPTS if k in step}

    # Shell step
    if "shell" in step:
        return ("shell", step["shell"], {}, opts)

    # Explicit form: {cmd: "...", params: {...}}
    if "cmd" in step:
        cmd = step["cmd"]
        params = step.get("params") or {}
        # Route dismiss_system through AX, not the dylib websocket
        if cmd == "dialog" and params.get("action") == "dismiss_system":
            return ("dismiss_system", "dismiss_system", {}, opts)
        return ("pepper", cmd, params, opts)

    # Sugar form: find the first key that matches a sugar mapping
    for key, expander in _SUGAR.items():
        if key in step:
            cmd, params = expander(step[key])
            # dismiss_system routes through AX, not the dylib websocket
            if cmd == "dismiss_system":
                return ("dismiss_system", "dismiss_system", params, opts)
            return ("pepper", cmd, params, opts)

    # Unknown step -- treat first non-option key as a raw command
    for key in step:
        if key not in _STEP_OPTS:
            val = step[key]
            return ("pepper", key, val if isinstance(val, dict) else {}, opts)

    raise ValueError(f"Cannot parse step: {step}")


# ---------------------------------------------------------------------------
# Step execution
# ---------------------------------------------------------------------------

def run_pepper_step(host: str, port: int, cmd: str, params: dict,
                    timeout: float) -> StepResult:
    """Send a Pepper command and return a StepResult."""
    msg = make_command(cmd, params or None)
    name = _step_label("pepper", cmd, params)
    t0 = time.monotonic()
    try:
        resp = send_command_sync(host, port, msg, timeout=timeout)
    except CrashError as e:
        return StepResult(
            name=name, status="error",
            elapsed=time.monotonic() - t0,
            message=f"App crashed: {e}",
        )
    except (ConnectionRefusedError, ConnectionResetError, OSError) as e:
        return StepResult(
            name=name, status="error",
            elapsed=time.monotonic() - t0,
            message=f"Connection error: {e}",
        )
    except TimeoutError:
        return StepResult(
            name=name, status="error",
            elapsed=time.monotonic() - t0,
            message=f"Timeout after {timeout}s",
        )

    elapsed = time.monotonic() - t0
    status_val = resp.get("status", "")
    data = resp.get("data", {})

    # verify command: check data.passed
    if cmd == "verify" and status_val == "ok" and isinstance(data, dict) and data.get("passed") is False:
        results_detail = data.get("results", [])
        fail_msgs = [r.get("message", "") for r in results_detail if not r.get("passed")]
        return StepResult(
            name=name, status="fail",
            elapsed=elapsed, response=resp,
            message="; ".join(fail_msgs) or "Verification failed",
        )

    if status_val != "ok":
        err_msg = ""
        if isinstance(data, dict):
            err_msg = data.get("message", "") or data.get("error", "")
        return StepResult(
            name=name, status="fail",
            elapsed=elapsed, response=resp,
            message=err_msg or f"Command returned status: {status_val}",
        )

    return StepResult(name=name, status="pass", elapsed=elapsed, response=resp)


def run_shell_step(command: str, timeout: float) -> StepResult:
    """Run a shell command and return a StepResult."""
    name = _step_label("shell", command, {})
    t0 = time.monotonic()
    try:
        result = subprocess.run(
            command, shell=True, capture_output=True, text=True,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired:
        return StepResult(
            name=name, status="error",
            elapsed=time.monotonic() - t0,
            message=f"Shell timeout after {timeout}s",
        )
    except OSError as e:
        return StepResult(
            name=name, status="error",
            elapsed=time.monotonic() - t0,
            message=f"Shell error: {e}",
        )

    elapsed = time.monotonic() - t0
    if result.returncode != 0:
        output = (result.stderr or result.stdout or "").strip()
        return StepResult(
            name=name, status="fail", elapsed=elapsed,
            message=f"Exit code {result.returncode}: {output[:200]}",
        )

    return StepResult(name=name, status="pass", elapsed=elapsed)


def run_dismiss_system_step(timeout: float) -> StepResult:
    """Dismiss a system dialog via macOS Accessibility API."""
    name = "dismiss_system"
    t0 = time.monotonic()
    deadline = t0 + timeout

    # Retry until timeout — dialog may take a moment to appear
    while time.monotonic() < deadline:
        try:
            result = find_and_dismiss_dialog()
        except Exception as e:
            return StepResult(
                name=name, status="error",
                elapsed=time.monotonic() - t0,
                message=f"AX error: {e}",
            )

        if result.get("dismissed"):
            return StepResult(
                name=name, status="pass",
                elapsed=time.monotonic() - t0,
                response=result,
            )

        time.sleep(0.5)

    # No dialog found — pass anyway (permission may have been pre-granted)
    return StepResult(
        name=name, status="pass",
        elapsed=time.monotonic() - t0,
        message="No system dialog found (already dismissed or not shown)",
    )


def _step_label(kind: str, cmd: str, params: dict) -> str:
    if kind == "shell":
        return f"shell: {cmd[:60]}"
    summary = cmd
    if params:
        # Show first meaningful param value for readability
        for key in ("text", "screen", "element", "direction", "id", "deeplink"):
            if key in params:
                summary = f"{cmd} {key}={params[key]}"
                break
    return summary


# ---------------------------------------------------------------------------
# Test and suite execution
# ---------------------------------------------------------------------------

def _run_steps(host: str, port: int, steps: list[dict], config: dict,
               verbose: bool = False) -> tuple[list[StepResult], bool]:
    """Run a list of steps. Returns (results, all_passed)."""
    results = []
    all_passed = True
    default_timeout = config.get("timeout", 10)

    for step in steps:
        kind, cmd, params, opts = expand_step(step)
        timeout = opts.get("timeout", default_timeout)
        retries = opts.get("retry", 0)
        retry_delay = opts.get("retry_delay", 1.0)

        result = None
        for attempt in range(1 + retries):
            if kind == "shell":
                result = run_shell_step(cmd, timeout)
            elif kind == "dismiss_system":
                result = run_dismiss_system_step(timeout)
            else:
                result = run_pepper_step(host, port, cmd, params, timeout)

            if result.status == "pass" or result.status == "error":
                break  # Don't retry errors (connection/crash)
            if attempt < retries:
                time.sleep(retry_delay)

        if verbose:
            icon = {"pass": "+", "fail": "x", "error": "!"}[result.status]
            retried = f" (attempt {attempt + 1})" if attempt > 0 else ""
            msg = f"  [{icon}] {result.name}{retried}"
            if result.message:
                msg += f" -- {result.message}"
            print(msg, file=sys.stderr)

        results.append(result)
        if result.status != "pass":
            all_passed = False
            break  # Stop this test's steps on first failure

    return results, all_passed


def run_test(host: str, port: int, test_def: dict, config: dict,
             verbose: bool = False) -> TestResult:
    """Run a single test (setup → steps → teardown)."""
    name = test_def.get("name", "unnamed")
    t0 = time.monotonic()
    all_steps = []

    # Setup
    setup = test_def.get("setup", [])
    if setup:
        if verbose:
            print("  [setup]", file=sys.stderr)
        setup_results, setup_ok = _run_steps(host, port, setup, config, verbose)
        all_steps.extend(setup_results)
        if not setup_ok:
            # Run teardown even if setup fails
            teardown = test_def.get("teardown", [])
            if teardown:
                if verbose:
                    print("  [teardown]", file=sys.stderr)
                td_results, _ = _run_steps(host, port, teardown, config, verbose)
                all_steps.extend(td_results)
            return TestResult(
                name=name, status="error",
                elapsed=time.monotonic() - t0,
                steps=all_steps, message="Setup failed",
            )

    # Steps
    steps = test_def.get("steps", [])
    step_results, steps_ok = _run_steps(host, port, steps, config, verbose)
    all_steps.extend(step_results)

    # Teardown (always runs)
    teardown = test_def.get("teardown", [])
    if teardown:
        if verbose:
            print("  [teardown]", file=sys.stderr)
        td_results, _ = _run_steps(host, port, teardown, config, verbose)
        all_steps.extend(td_results)

    status = "pass" if steps_ok else "fail"
    # Promote to error if any step had an error (crash, connection loss)
    if any(s.status == "error" for s in all_steps):
        status = "error"

    failed = [s for s in step_results if s.status != "pass"]
    message = failed[0].message if failed else ""

    return TestResult(
        name=name, status=status,
        elapsed=time.monotonic() - t0,
        steps=all_steps, message=message,
    )


def run_suite(host: str, port: int, suite_path: str,
              verbose: bool = False, stop_on_failure: bool = False,
              timeout_override: float | None = None,
              test_filter: str | None = None) -> SuiteResult:
    """Load a YAML suite file and run all tests."""
    path = Path(suite_path)
    if not path.exists():
        print(f"Error: File not found: {suite_path}", file=sys.stderr)
        sys.exit(2)

    try:
        with open(path) as f:
            data = yaml.safe_load(f)
    except yaml.YAMLError as e:
        print(f"Error: Invalid YAML in {suite_path}: {e}", file=sys.stderr)
        sys.exit(2)

    suite_name = data.get("suite", path.stem)
    config = data.get("config", {})
    tests = data.get("tests", [])

    if not tests:
        print(f"Error: No tests found in {suite_path}", file=sys.stderr)
        sys.exit(2)

    # CLI overrides
    if not stop_on_failure:
        stop_on_failure = config.get("stop_on_failure", False)
    if timeout_override is not None:
        config["timeout"] = timeout_override

    # Filter tests by name
    if test_filter:
        tests = [t for t in tests if test_filter.lower() in t.get("name", "").lower()]
        if not tests:
            print(f"Error: No tests matching '{test_filter}'", file=sys.stderr)
            sys.exit(2)

    auto_reset = config.get("reset", True)

    t0 = time.monotonic()
    results = []
    for i, test_def in enumerate(tests):
        test_name = test_def.get("name", "unnamed")

        # Reset app state between tests (pop nav, dismiss modals, etc.)
        if auto_reset and i > 0:
            try:
                msg = make_command("test", {"action": "reset"})
                send_command_sync(host, port, msg, timeout=5)
            except (ConnectionRefusedError, TimeoutError, OSError, CrashError):
                pass  # Best effort — don't fail the suite

        if verbose:
            print(f"\n--- {test_name} ---", file=sys.stderr)

        result = run_test(host, port, test_def, config, verbose)
        results.append(result)

        if result.status != "pass" and stop_on_failure:
            break

    return SuiteResult(
        name=suite_name,
        elapsed=time.monotonic() - t0,
        tests=results,
    )


# ---------------------------------------------------------------------------
# Output formatting
# ---------------------------------------------------------------------------

def format_tap(result: SuiteResult) -> str:
    """Format as TAP (Test Anything Protocol) -- human-readable."""
    lines = ["TAP version 13", f"1..{len(result.tests)}"]
    for i, test in enumerate(result.tests, 1):
        if test.status == "pass":
            lines.append(f"ok {i} - {test.name}")
        elif test.status == "fail":
            lines.append(f"not ok {i} - {test.name}")
            if test.message:
                lines.append("  ---")
                lines.append(f"  message: {test.message}")
                lines.append("  ---")
        else:
            lines.append(f"not ok {i} - {test.name} # ERROR")
            if test.message:
                lines.append("  ---")
                lines.append(f"  message: {test.message}")
                lines.append("  ---")

    p, f, e = result.passed, result.failed, result.errors
    lines.append(f"# {len(result.tests)} tests: {p} passed, {f} failed, {e} errors ({result.elapsed:.2f}s)")
    return "\n".join(lines)


def format_json(result: SuiteResult) -> str:
    """Format as JSON report."""
    return json.dumps({
        "suite": result.name,
        "tests": len(result.tests),
        "passed": result.passed,
        "failed": result.failed,
        "errors": result.errors,
        "time": round(result.elapsed, 3),
        "ok": result.ok,
        "results": [
            {
                "name": t.name,
                "status": t.status,
                "time": round(t.elapsed, 3),
                "message": t.message,
                "steps": [
                    {
                        "name": s.name,
                        "status": s.status,
                        "time": round(s.elapsed, 3),
                        "message": s.message,
                    }
                    for s in t.steps
                ],
            }
            for t in result.tests
        ],
    }, indent=2)


def format_junit(result: SuiteResult) -> str:
    """Format as JUnit XML."""
    testsuites = ET.Element("testsuites")
    testsuite = ET.SubElement(testsuites, "testsuite", {
        "name": result.name,
        "tests": str(len(result.tests)),
        "failures": str(result.failed),
        "errors": str(result.errors),
        "time": f"{result.elapsed:.3f}",
    })

    for test in result.tests:
        tc = ET.SubElement(testsuite, "testcase", {
            "name": test.name,
            "classname": result.name,
            "time": f"{test.elapsed:.3f}",
        })
        if test.status == "fail":
            failure = ET.SubElement(tc, "failure", {"message": test.message})
            # Include step details
            step_detail = "\n".join(
                f"  [{s.status}] {s.name}: {s.message}" for s in test.steps if s.status != "pass"
            )
            failure.text = step_detail
        elif test.status == "error":
            error = ET.SubElement(tc, "error", {"message": test.message})
            step_detail = "\n".join(
                f"  [{s.status}] {s.name}: {s.message}" for s in test.steps if s.status != "pass"
            )
            error.text = step_detail

    ET.indent(testsuites)
    return ET.tostring(testsuites, encoding="unicode", xml_declaration=True)


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="pepper-test",
        description="Run deterministic UI test flows via Pepper.",
    )
    parser.add_argument("--file", "-f", required=True, help="YAML test suite file")
    parser.add_argument("--host", default=None, help="Pepper host (default: auto-discover)")
    parser.add_argument("--port", type=int, default=None, help="Pepper port (default: auto-discover)")
    parser.add_argument(
        "--format", choices=["tap", "json", "junit"], default="tap",
        dest="report_format", help="Output format (default: tap)",
    )
    parser.add_argument("--output", "-o", default=None, help="Output file (default: stdout)")
    parser.add_argument("--timeout", type=float, default=None, help="Per-step timeout override")
    parser.add_argument("--stop-on-failure", action="store_true", help="Stop on first test failure")
    parser.add_argument("--test", "-t", default=None, help="Run only tests matching this name (substring)")
    parser.add_argument("--dry-run", action="store_true", help="Parse and expand steps without executing")
    parser.add_argument("--verbose", "-v", action="store_true", help="Print each step as it runs")

    # Lifecycle flags — when --project is set, pepper-test handles the full
    # boot → build → inject → test → teardown cycle.
    lifecycle = parser.add_argument_group("lifecycle", "Full headless mode (build + deploy + test)")
    lifecycle.add_argument("--project", help="Path to .xcodeproj or .xcworkspace (enables lifecycle mode)")
    lifecycle.add_argument("--scheme", default=None, help="Xcode scheme (default: project name)")
    lifecycle.add_argument("--simulator", default=None, help="Simulator UDID (default: auto)")
    lifecycle.add_argument("--server-timeout", type=int, default=30,
                           help="Seconds to wait for Pepper server (default: 30)")
    return parser


def _output_result(result: SuiteResult, args: argparse.Namespace) -> None:
    """Format and write test results."""
    formatters = {
        "tap": format_tap,
        "json": format_json,
        "junit": format_junit,
    }
    output = formatters[args.report_format](result)

    if args.output:
        with open(args.output, "w") as f:
            f.write(output)
        print(f"Report written to {args.output}", file=sys.stderr)
    else:
        print(output)

    if args.report_format == "junit":
        total = len(result.tests)
        print(
            f"\n{total} tests: {result.passed} passed, {result.failed} failed, "
            f"{result.errors} errors ({result.elapsed:.2f}s)",
            file=sys.stderr,
        )


def _dry_run(args: argparse.Namespace) -> None:
    """Parse suite, expand all steps, print without executing."""
    path = Path(args.file)
    if not path.exists():
        print(f"Error: File not found: {args.file}", file=sys.stderr)
        sys.exit(2)

    with open(path) as f:
        data = yaml.safe_load(f)

    tests = data.get("tests", [])
    if args.test:
        tests = [t for t in tests if args.test.lower() in t.get("name", "").lower()]

    print(f"Suite: {data.get('suite', path.stem)}")
    print(f"Tests: {len(tests)}\n")

    for test_def in tests:
        name = test_def.get("name", "unnamed")
        print(f"--- {name} ---")
        for phase in ("setup", "steps", "teardown"):
            steps = test_def.get(phase, [])
            if not steps:
                continue
            if phase != "steps":
                print(f"  [{phase}]")
            for step in steps:
                try:
                    kind, cmd, params, opts = expand_step(step)
                    opt_str = f"  opts={opts}" if opts else ""
                    if kind == "shell":
                        print(f"    shell: {cmd}{opt_str}")
                    else:
                        print(f"    {cmd} {params}{opt_str}")
                except ValueError as e:
                    print(f"    ERROR: {e}", file=sys.stderr)
                    sys.exit(2)
        print()

    print("Dry run complete — all steps parsed successfully.")


def _load_config_file(args: argparse.Namespace) -> None:
    """Load defaults from .pepper-test.yml if it exists and CLI flags aren't set."""
    config_path = Path(".pepper-test.yml")
    if not config_path.exists():
        return
    try:
        with open(config_path) as f:
            config = yaml.safe_load(f) or {}
    except yaml.YAMLError:
        return

    # Only fill in values not already set via CLI
    if not args.project and "project" in config:
        args.project = config["project"]
    if not args.scheme and "scheme" in config:
        args.scheme = config["scheme"]
    if not args.file and "suite" in config:
        args.file = config["suite"]
    if args.server_timeout == 30 and "server_timeout" in config:
        args.server_timeout = config["server_timeout"]


def main(argv: list[str] | None = None):
    parser = build_parser()
    args = parser.parse_args(argv)
    _load_config_file(args)

    if args.dry_run:
        _dry_run(args)
        return

    if args.project:
        # Lifecycle mode: build, deploy, test, teardown
        from .test_lifecycle import run_lifecycle, teardown

        sim, bundle_id = run_lifecycle(
            project=args.project,
            scheme=args.scheme,
            simulator=args.simulator,
            server_timeout=args.server_timeout,
        )

        # Ensure teardown runs on Ctrl-C / kill
        def _signal_teardown(signum: int, frame: object) -> None:
            print("\nInterrupted — cleaning up...", file=sys.stderr)
            teardown(sim, bundle_id)
            sys.exit(130)

        signal.signal(signal.SIGINT, _signal_teardown)
        signal.signal(signal.SIGTERM, _signal_teardown)

        try:
            result = run_suite(
                sim.host, sim.port, args.file,
                verbose=args.verbose,
                stop_on_failure=args.stop_on_failure,
                timeout_override=args.timeout,
                test_filter=args.test,
            )
            _output_result(result, args)
        finally:
            teardown(sim, bundle_id)

        sys.exit(0 if result.ok else 1)

    # Attach mode: connect to already-running Pepper
    host = args.host or DEFAULT_HOST
    port = args.port
    if port is None:
        try:
            port = discover_port()
        except RuntimeError as e:
            print(f"Error: {e}", file=sys.stderr)
            print("Specify --host and --port, or ensure a Pepper instance is running.", file=sys.stderr)
            sys.exit(2)

    result = run_suite(
        host, port, args.file,
        verbose=args.verbose,
        stop_on_failure=args.stop_on_failure,
        timeout_override=args.timeout,
        test_filter=args.test,
    )
    _output_result(result, args)
    sys.exit(0 if result.ok else 1)


if __name__ == "__main__":
    main()

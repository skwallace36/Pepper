#!/usr/bin/env python3
"""Generate test-app/COVERAGE.md from PepperDispatcher source + coverage-status.json.

Source of truth:
  - Commands: dylib/commands/PepperDispatcher.swift (registerBuiltins)
  - Variants: dylib/commands/handlers/*Handler.swift (switch on action/mode/type/direction/value)
  - Status:   test-app/coverage-status.json (manually maintained)

Usage:
  python3 scripts/gen-coverage.py          # write test-app/COVERAGE.md
  python3 scripts/gen-coverage.py --check  # exit 1 if COVERAGE.md is stale
"""

import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DISPATCHER = os.path.join(ROOT, "dylib", "commands", "PepperDispatcher.swift")
HANDLERS_DIR = os.path.join(ROOT, "dylib", "commands", "handlers")
STATUS_FILE = os.path.join(ROOT, "test-app", "coverage-status.json")
OUTPUT_FILE = os.path.join(ROOT, "test-app", "COVERAGE.md")

# Params that act like "action" — handler switches on these to determine behavior
ACTION_PARAMS = ["action", "mode", "type", "direction", "value"]

# Case values to skip — aliases, internal sub-cases, not top-level variants
SKIP_CASES = {
    "landscape-left",       # alias for landscape_left
    "landscape-right",      # alias for landscape_right
    "portrait-upside-down", # alias for portrait_upside_down
    "content_area",         # introspect internal sub-case
    "unlabeled_interactive",
    "icon_button",
}


def parse_registered_commands():
    """Extract command names from PepperDispatcher.registerBuiltins()."""
    with open(DISPATCHER) as f:
        src = f.read()

    m = re.search(r'func registerBuiltins\(\)\s*\{(.+)', src, re.DOTALL)
    if not m:
        sys.exit("Could not find registerBuiltins() in dispatcher")
    body = m.group(1)

    commands = []

    # Closure-based: register("ping") { ... }
    for m in re.finditer(r'register\("(\w+)"\)', body):
        commands.append(m.group(1))

    # Handler-based: register(FooHandler(...))
    for m in re.finditer(r'register\((\w+Handler)\(', body):
        handler_class = m.group(1)
        cmd_name = handler_to_command(handler_class)
        if cmd_name:
            commands.append(cmd_name)

    return commands


def handler_to_command(handler_class):
    """Map handler class name to command name by reading commandName from file."""
    filepath = os.path.join(HANDLERS_DIR, handler_class + ".swift")

    if not os.path.exists(filepath):
        for fname in os.listdir(HANDLERS_DIR):
            if not fname.endswith(".swift"):
                continue
            fp = os.path.join(HANDLERS_DIR, fname)
            with open(fp) as f:
                src = f.read()
            if re.search(rf'(?:class|struct)\s+{handler_class}\b', src):
                filepath = fp
                break
        else:
            return None

    with open(filepath) as f:
        src = f.read()

    # Handle files with multiple classes (e.g. SubscribeHandler.swift)
    class_pattern = rf'(?:class|struct)\s+{handler_class}\b.*?(?=(?:class|struct)\s+\w+Handler\b|\Z)'
    class_match = re.search(class_pattern, src, re.DOTALL)
    if class_match:
        m = re.search(r'(?:var|let)\s+commandName.*?"(\w+)"', class_match.group(0))
        if m:
            return m.group(1)

    m = re.search(r'(?:var|let)\s+commandName.*?"(\w+)"', src)
    return m.group(1) if m else None


def parse_variants(command_name):
    """Extract variants from a handler file via switch case patterns."""
    handler_file = find_handler_file(command_name)
    if not handler_file:
        return []

    with open(handler_file) as f:
        src = f.read()

    for param in ACTION_PARAMS:
        if f'params?["{param}"]' not in src:
            continue

        cases = []
        for m in re.finditer(r'case\s+"([^"]+)":', src):
            val = m.group(1)
            if val not in SKIP_CASES:
                cases.append(val)

        # Deduplicate preserving order
        seen = set()
        unique = []
        for c in cases:
            if c not in seen:
                seen.add(c)
                unique.append(c)

        if unique:
            return unique

    return []


def find_handler_file(command_name):
    """Find the handler Swift file for a command."""
    for fname in os.listdir(HANDLERS_DIR):
        if not fname.endswith(".swift"):
            continue
        filepath = os.path.join(HANDLERS_DIR, fname)
        with open(filepath) as f:
            src = f.read()
        for m in re.finditer(r'(?:var|let)\s+commandName.*?"(\w+)"', src):
            if m.group(1) == command_name:
                return filepath
    return None


def load_status():
    """Load coverage-status.json."""
    if not os.path.exists(STATUS_FILE):
        return {}
    with open(STATUS_FILE) as f:
        return json.load(f)


def get_variants_for_command(cmd, source_variants, status):
    """Merge source-parsed variants with extras from status JSON."""
    variants = list(source_variants)
    prefix = f"{cmd}."
    for key in status:
        if key.startswith(prefix):
            variant = key[len(prefix):]
            if variant not in variants:
                variants.append(variant)
    return variants


def generate_markdown(commands, variants_map, status):
    """Generate COVERAGE.md content."""
    lines = [
        "<!-- AUTO-GENERATED by scripts/gen-coverage.py — do not edit by hand -->",
        "# Test Coverage",
        "",
        "## How This Works",
        "",
        "This file is auto-generated. Do not edit it directly.",
        "",
        "**Sources of truth:**",
        "- **Commands** — parsed from `dylib/commands/PepperDispatcher.swift` (`registerBuiltins()`)",
        "- **Variants** — parsed from handler switch cases (`case \"action\":` patterns)",
        "- **Status & test surfaces** — `test-app/coverage-status.json` (the only file you edit)",
        "",
        "**Workflow:**",
        "1. Add/change a command → it auto-appears as `untested` next time you regenerate",
        "2. Update `coverage-status.json` with status, test surface, and notes",
        "3. Run `make coverage` to regenerate this file",
        "4. `make coverage-check` verifies this file is in sync (for CI/pre-commit)",
        "",
        "Bugs: see [GitHub Issues](https://github.com/skwallace36/Pepper/issues?q=label%3Abug)",
        "",
        "## Coverage Matrix",
        "",
        "| Command | Variant | Status | Test Surface | Notes |",
        "|---------|---------|--------|-------------|-------|",
    ]

    total = 0
    by_status = {}

    for cmd in commands:
        variants = variants_map.get(cmd, [])
        if variants:
            for variant in variants:
                key = f"{cmd}.{variant}"
                s = status.get(key, {})
                st = s.get("status", "untested")
                surface = s.get("surface", "")
                notes = s.get("notes", "")
                lines.append(f"| `{cmd}` | {variant} | {st} | {surface} | {notes} |")
                by_status[st] = by_status.get(st, 0) + 1
                total += 1
        else:
            s = status.get(cmd, {})
            st = s.get("status", "untested")
            surface = s.get("surface", "")
            notes = s.get("notes", "")
            lines.append(f"| `{cmd}` | — | {st} | {surface} | {notes} |")
            by_status[st] = by_status.get(st, 0) + 1
            total += 1

    lines.append("")
    lines.append("## Summary")
    lines.append("")
    lines.append(f"**{total} test points** across {len(commands)} commands.")
    lines.append("")
    for st in ["pass", "partial", "fail", "crash", "untested"]:
        if st in by_status:
            lines.append(f"- {st}: {by_status[st]}")
    lines.append("")

    # Gaps: entries with "NEEDS:" in surface
    gaps = []
    for cmd in commands:
        variants = variants_map.get(cmd, [])
        if variants:
            for variant in variants:
                key = f"{cmd}.{variant}"
                s = status.get(key, {})
                if "NEEDS:" in s.get("surface", ""):
                    gaps.append((f"`{cmd}` {variant}", s["surface"].replace("NEEDS: ", "")))
        else:
            s = status.get(cmd, {})
            if "NEEDS:" in s.get("surface", ""):
                gaps.append((f"`{cmd}`", s["surface"].replace("NEEDS: ", "")))

    if gaps:
        lines.append("## Test App Gaps")
        lines.append("")
        lines.append("Commands that need test app changes before they can be tested:")
        lines.append("")
        for cmd_label, need in gaps:
            lines.append(f"- {cmd_label} — {need}")
        lines.append("")

    return "\n".join(lines) + "\n"


def main():
    check_mode = "--check" in sys.argv

    commands = parse_registered_commands()
    status = load_status()

    # Build variants map: source-parsed + status JSON extras
    variants_map = {}
    for cmd in commands:
        source_variants = parse_variants(cmd)
        all_variants = get_variants_for_command(cmd, source_variants, status)
        if all_variants:
            variants_map[cmd] = all_variants

    md = generate_markdown(commands, variants_map, status)

    if check_mode:
        if os.path.exists(OUTPUT_FILE):
            with open(OUTPUT_FILE) as f:
                existing = f.read()
            if existing == md:
                print("COVERAGE.md is up to date.")
                sys.exit(0)
            else:
                print("COVERAGE.md is stale. Run: python3 scripts/gen-coverage.py")
                sys.exit(1)
        else:
            print("COVERAGE.md does not exist. Run: python3 scripts/gen-coverage.py")
            sys.exit(1)

    with open(OUTPUT_FILE, "w") as f:
        f.write(md)

    print(f"Generated {OUTPUT_FILE}")
    print(f"  {len(commands)} commands, {sum(len(v) for v in variants_map.values())} sub-variants")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Generate test-app/COVERAGE.md from PepperDispatcher source + coverage-status.json.

Source of truth:
  - Commands: dylib/commands/PepperDispatcher.swift (registerBuiltins)
  - Actions:  dylib/commands/handlers/*Handler.swift (switch on action/mode/type/direction/value)
  - Categories: docs/COMMANDS.md (command summary table)
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
COMMANDS_MD = os.path.join(ROOT, "docs", "COMMANDS.md")
STATUS_FILE = os.path.join(ROOT, "test-app", "coverage-status.json")
OUTPUT_FILE = os.path.join(ROOT, "test-app", "COVERAGE.md")

# Params that act like "action" — handler switches on these to determine behavior
ACTION_PARAMS = ["action", "mode", "type", "direction", "value"]

# Case values to skip — these are aliases, internal, or non-testable variants
SKIP_CASES = {
    "landscape-left",      # alias for landscape_left
    "landscape-right",     # alias for landscape_right
    "portrait-upside-down", # alias for portrait_upside_down
    "content_area",        # introspect internal sub-case, not a mode
    "unlabeled_interactive",
    "icon_button",
}


def parse_registered_commands():
    """Extract command names from PepperDispatcher.registerBuiltins()."""
    with open(DISPATCHER) as f:
        src = f.read()

    # Only parse inside registerBuiltins()
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

    # SubscribeHandler.swift defines both subscribe and unsubscribe
    # The dispatcher registers them separately, so we handle via the class name
    if not os.path.exists(filepath):
        # Try all handler files
        for fname in os.listdir(HANDLERS_DIR):
            if not fname.endswith(".swift"):
                continue
            fp = os.path.join(HANDLERS_DIR, fname)
            with open(fp) as f:
                src = f.read()
            # Check if this file defines the class
            if re.search(rf'(?:class|struct)\s+{handler_class}\b', src):
                filepath = fp
                break
        else:
            return None

    with open(filepath) as f:
        src = f.read()

    # Find commandName for this specific class
    # Handle files with multiple classes (e.g. SubscribeHandler.swift)
    class_pattern = rf'(?:class|struct)\s+{handler_class}\b.*?(?=(?:class|struct)\s+\w+Handler\b|\Z)'
    class_match = re.search(class_pattern, src, re.DOTALL)
    if class_match:
        class_src = class_match.group(0)
        m = re.search(r'(?:var|let)\s+commandName.*?"(\w+)"', class_src)
        if m:
            return m.group(1)

    # Fallback: first commandName in file
    m = re.search(r'(?:var|let)\s+commandName.*?"(\w+)"', src)
    if m:
        return m.group(1)

    return None


def parse_variants(command_name):
    """Extract action/mode/type/direction variants from a handler file.

    Returns a list of (param_name, variant_values) or empty list if no variants.
    For handlers with variants, returns the variant values as the "actions".
    """
    handler_file = find_handler_file(command_name)
    if not handler_file:
        return []

    with open(handler_file) as f:
        src = f.read()

    # Check which action-like param this handler uses
    for param in ACTION_PARAMS:
        if f'params?["{param}"]' not in src:
            continue

        # Find switch statement on this param's variable
        # Handlers typically do: let action = command.params?["action"]...
        # then: switch action { case "foo": ... }
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

    # Check for param-driven handlers (like tap) — pull variants from status JSON
    # These get their variants entirely from the status file
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


def parse_categories():
    """Extract command -> category mapping from COMMANDS.md summary table."""
    categories = {}
    in_summary = False

    with open(COMMANDS_MD) as f:
        for line in f:
            # Only parse the Command Summary table
            if "## Command Summary" in line:
                in_summary = True
                continue
            if in_summary and line.startswith("## ") and "Command Summary" not in line:
                break
            if not in_summary:
                continue

            # Match: | `command` | category | description | ... |
            m = re.match(r'\|\s*`(\w+)`\s*\|\s*([^|]+?)\s*\|', line)
            if m:
                cmd = m.group(1)
                cat = m.group(2).strip()
                categories[cmd] = cat

    return categories


# Canonical category ordering
CATEGORY_ORDER = [
    "meta",
    "navigation",
    "interaction",
    "observation",
    "inspection",
    "flow control",
    "automation",
    "events",
    "network",
    "toolbox",
]


def load_status():
    """Load coverage-status.json."""
    if not os.path.exists(STATUS_FILE):
        return {}
    with open(STATUS_FILE) as f:
        return json.load(f)


def get_variants_for_command(cmd, source_variants, status):
    """Get the final list of variants for a command.

    Merges source-parsed variants with any extra variants defined in status JSON.
    This handles param-driven commands (like tap) where variants come from status.
    """
    # Start with source-parsed variants
    variants = list(source_variants)

    # Add any variants from status JSON that aren't already covered
    prefix = f"{cmd}."
    for key in status:
        if key.startswith(prefix):
            variant = key[len(prefix):]
            if variant not in variants:
                variants.append(variant)

    return variants


def generate_markdown(commands, variants_map, categories, status):
    """Generate COVERAGE.md content."""
    lines = [
        "<!-- AUTO-GENERATED by scripts/gen-coverage.py — do not edit by hand -->",
        "# Test Coverage",
        "",
        "Derived from `PepperDispatcher.registerBuiltins()`. Every registered command gets a row.",
        "",
        "Status: `pass` | `fail` | `crash` | `partial` | `untested`",
        "",
        "Bugs: see [`BUGS.md`](../BUGS.md) at project root.",
        "",
    ]

    # Group commands by category
    grouped = {}
    for cmd in commands:
        cat = categories.get(cmd, "uncategorized")
        grouped.setdefault(cat, []).append(cmd)

    # Sort categories by canonical order
    ordered_cats = sorted(
        grouped.keys(),
        key=lambda c: CATEGORY_ORDER.index(c) if c in CATEGORY_ORDER else 999,
    )

    for cat in ordered_cats:
        title = cat.replace("_", " ").title()
        if cat == "flow control":
            title = "Flow Control"
        lines.append(f"## {title}")
        lines.append("")
        lines.append("| Command | Action | Status | Test Surface | Notes |")
        lines.append("|---------|--------|--------|-------------|-------|")

        for cmd in grouped[cat]:
            variants = variants_map.get(cmd, [])
            if variants:
                for variant in variants:
                    key = f"{cmd}.{variant}"
                    s = status.get(key, {})
                    st = s.get("status", "untested")
                    surface = s.get("surface", "")
                    notes = s.get("notes", "")
                    lines.append(
                        f"| `{cmd}` | {variant} | {st} | {surface} | {notes} |"
                    )
            else:
                s = status.get(cmd, {})
                st = s.get("status", "untested")
                surface = s.get("surface", "")
                notes = s.get("notes", "")
                lines.append(f"| `{cmd}` | — | {st} | {surface} | {notes} |")

        lines.append("")

    # Summary
    total = 0
    by_status = {}
    for cmd in commands:
        variants = variants_map.get(cmd, [])
        if variants:
            for variant in variants:
                key = f"{cmd}.{variant}"
                st = status.get(key, {}).get("status", "untested")
                by_status[st] = by_status.get(st, 0) + 1
                total += 1
        else:
            st = status.get(cmd, {}).get("status", "untested")
            by_status[st] = by_status.get(st, 0) + 1
            total += 1

    lines.append("## Summary")
    lines.append("")
    lines.append(f"**{total} test points** across {len(commands)} commands.")
    lines.append("")
    for st in ["pass", "partial", "fail", "crash", "untested"]:
        if st in by_status:
            lines.append(f"- {st}: {by_status[st]}")
    lines.append("")

    return "\n".join(lines) + "\n"


def main():
    check_mode = "--check" in sys.argv

    commands = parse_registered_commands()
    categories = parse_categories()
    status = load_status()

    # Build variants map: source-parsed + status JSON extras
    variants_map = {}
    for cmd in commands:
        source_variants = parse_variants(cmd)
        all_variants = get_variants_for_command(cmd, source_variants, status)
        if all_variants:
            variants_map[cmd] = all_variants

    md = generate_markdown(commands, variants_map, categories, status)

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
    uncategorized = [c for c in commands if c not in categories]
    if uncategorized:
        print(f"  WARNING: uncategorized commands: {uncategorized}")
        print(f"  Add them to docs/COMMANDS.md summary table.")


if __name__ == "__main__":
    main()

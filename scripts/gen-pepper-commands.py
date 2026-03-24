#!/usr/bin/env python3
"""Generate tools/pepper_commands.py from Swift handler commandName properties.

Source of truth:
  - dylib/commands/handlers/*Handler.swift (let commandName = "...")

Usage:
  python3 scripts/gen-pepper-commands.py          # write tools/pepper_commands.py
  python3 scripts/gen-pepper-commands.py --check  # exit 1 if file is stale
"""

import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HANDLERS_DIR = os.path.join(ROOT, "dylib", "commands", "handlers")
OUTPUT_FILE = os.path.join(ROOT, "tools", "pepper_commands.py")

HEADER = '''\
# @generated — do not edit directly.
# Regenerate with: python3 scripts/gen-pepper-commands.py
# Or via: make commands
"""Command name constants derived from Swift handler commandName properties.

Import these instead of bare strings to get typo-safety and IDE completion::

    # example
    from pepper_commands import CMD_TAP, CMD_SCROLL
    return await act_and_look(simulator, CMD_TAP, params)
"""


'''


def _to_const(name: str) -> str:
    """Convert snake_case command name to CMD_SNAKE_CASE constant name."""
    return "CMD_" + name.upper()


def collect_commands() -> list[str]:
    """Return sorted list of unique command names from Swift handlers."""
    pattern = re.compile(r'let\s+commandName\s*=\s*"([^"]+)"')
    names: set[str] = set()
    for fname in sorted(os.listdir(HANDLERS_DIR)):
        if not fname.endswith(".swift"):
            continue
        path = os.path.join(HANDLERS_DIR, fname)
        with open(path) as f:
            for line in f:
                m = pattern.search(line)
                if m:
                    names.add(m.group(1))
    return sorted(names)


def generate(commands: list[str]) -> str:
    lines = [HEADER]
    for cmd in commands:
        const = _to_const(cmd)
        lines.append(f'{const} = "{cmd}"\n')
    lines.append("\n# Alias used internally for the look/introspect map command\n")
    lines.append('CMD_LOOK = "look"\n')
    return "".join(lines)


def main() -> None:
    check_mode = "--check" in sys.argv

    commands = collect_commands()
    content = generate(commands)

    if check_mode:
        if not os.path.exists(OUTPUT_FILE):
            print("pepper_commands.py does not exist — run: make commands", file=sys.stderr)
            sys.exit(1)
        with open(OUTPUT_FILE) as f:
            current = f.read()
        if current != content:
            print("pepper_commands.py is stale — run: make commands", file=sys.stderr)
            sys.exit(1)
        print("pepper_commands.py is up to date.")
    else:
        with open(OUTPUT_FILE, "w") as f:
            f.write(content)
        print(f"Generated {OUTPUT_FILE} with {len(commands)} commands.")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""
Inject Pepper dylib environment variables into an Xcode scheme.

Adds DYLD_INSERT_LIBRARIES and PEPPER_ADAPTER to the LaunchAction's
EnvironmentVariables so that every Cmd+R in Xcode auto-injects Pepper.

Also adds a build pre-action that ensures the Pepper dylib exists.

Idempotent — safe to run multiple times. Checks for existing injection
before modifying.

Modes:
    inject-xcode-scheme.py <scheme-path>                  # Inject into file
    inject-xcode-scheme.py --remove <scheme-path>         # Remove from file
    inject-xcode-scheme.py --setup-filter <scheme-path>   # Configure git smudge/clean filter
    inject-xcode-scheme.py --filter-clean                 # stdin→stdout: strip injection
    inject-xcode-scheme.py --filter-smudge                # stdin→stdout: add injection
"""

import argparse
import os
import subprocess
import sys

MARKER = "DYLD_INSERT_LIBRARIES"
BUILD_MARKER = "Build Pepper dylib"


def detect_pepper_root():
    """Auto-detect Pepper project root from this script's location."""
    return os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def env_var_xml(key, value, enabled=True):
    """Format a single Xcode scheme EnvironmentVariable XML element."""
    is_enabled = "YES" if enabled else "NO"
    return (
        f'         <EnvironmentVariable\n'
        f'            key = "{key}"\n'
        f'            value = "{value}"\n'
        f'            isEnabled = "{is_enabled}">\n'
        f'         </EnvironmentVariable>\n'
    )


def build_preaction_xml(pepper_root):
    """Format the build pre-action that ensures the Pepper dylib exists."""
    # Escape for XML: use &#10; for newlines inside scriptText
    script = (
        f'# {BUILD_MARKER}&#10;'
        f'PEPPER=&quot;{pepper_root}&quot;&#10;'
        f'if [ ! -f &quot;$PEPPER/build/Pepper.framework/Pepper&quot; ]; then&#10;'
        f'    make -C &quot;$PEPPER&quot; build 2&gt;&amp;1 || true&#10;'
        f'fi&#10;'
    )
    return (
        f'         <ExecutionAction\n'
        f'            ActionType = "Xcode.IDEStandardExecutionActionsCore.ExecutionActionType.ShellScriptAction">\n'
        f'            <ActionContent\n'
        f'               title = "{BUILD_MARKER}"\n'
        f'               scriptText = "{script}">\n'
        f'            </ActionContent>\n'
        f'         </ExecutionAction>\n'
    )


def find_launch_action_range(content):
    """Find the start and end indices of <LaunchAction>...</LaunchAction>."""
    start = content.find("<LaunchAction")
    if start == -1:
        return None, None
    end = content.find("</LaunchAction>", start)
    if end == -1:
        return None, None
    end += len("</LaunchAction>")
    return start, end


def inject_env_vars(content, pepper_root, adapter):
    """Inject Pepper env vars into the LaunchAction EnvironmentVariables."""
    la_start, la_end = find_launch_action_range(content)
    if la_start is None:
        print("ERROR: No <LaunchAction> found in scheme", file=sys.stderr)
        return None

    la_section = content[la_start:la_end]

    # Build the env var XML to insert
    dylib_path = os.path.join(pepper_root, "build", "Pepper.framework", "Pepper")
    new_vars = env_var_xml("DYLD_INSERT_LIBRARIES", dylib_path)
    new_vars += env_var_xml("PEPPER_ADAPTER", adapter)

    # Find </EnvironmentVariables> within LaunchAction
    env_close = la_section.find("</EnvironmentVariables>")
    if env_close != -1:
        # Insert after the newline before </EnvironmentVariables> indentation
        # so our vars get their own properly-indented lines
        pos = env_close
        while pos > 0 and la_section[pos - 1] in (' ', '\t'):
            pos -= 1
        # pos is now at the newline; insert after it
        insert_pos = la_start + pos
        content = content[:insert_pos] + new_vars + content[insert_pos:]
    else:
        # No EnvironmentVariables section — create one before </LaunchAction>
        env_section = (
            '      <EnvironmentVariables>\n'
            + new_vars +
            '      </EnvironmentVariables>\n'
        )
        # Insert before </LaunchAction>
        close_la = content.find("</LaunchAction>")
        content = content[:close_la] + env_section + "   " + content[close_la:]

    return content


def inject_build_preaction(content, pepper_root):
    """Inject a build pre-action into LaunchAction that builds the Pepper dylib."""
    la_start, la_end = find_launch_action_range(content)
    if la_start is None:
        return content

    la_section = content[la_start:la_end]
    preaction_xml = build_preaction_xml(pepper_root)

    # Find <PreActions> within LaunchAction
    preactions_start = la_section.find("<PreActions>")
    if preactions_start != -1:
        # Insert after <PreActions>\n
        insert_after = la_section.find("\n", preactions_start) + 1
        insert_pos = la_start + insert_after
        content = content[:insert_pos] + preaction_xml + content[insert_pos:]
    else:
        # No PreActions — create one. Insert after the opening <LaunchAction ...> line
        la_line_end = content.find("\n", la_start) + 1
        # Walk forward to find the end of the opening tag attributes
        # The LaunchAction might span multiple lines
        tag_close = content.find(">", la_start)
        first_newline_after = content.find("\n", tag_close) + 1
        preactions_section = (
            '      <PreActions>\n'
            + preaction_xml +
            '      </PreActions>\n'
        )
        content = content[:first_newline_after] + preactions_section + content[first_newline_after:]

    return content


def remove_block(content, start_marker, end_tag):
    """Remove an XML block containing start_marker, bounded by end_tag."""
    idx = content.find(start_marker)
    if idx == -1:
        return content

    # Derive the opening tag from the closing tag: </Foo> → <Foo
    open_tag = "<" + end_tag[2:-1]  # "</ExecutionAction>" → "<ExecutionAction"

    # Walk backward to find the nearest opening tag before the marker
    search_region = content[:idx]
    tag_pos = search_region.rfind(open_tag)
    if tag_pos == -1:
        return content

    # Include leading whitespace on the tag's line
    nl = content.rfind('\n', 0, tag_pos)
    block_start = nl + 1 if nl != -1 else tag_pos

    # Walk forward to find the closing end_tag after the marker
    close_pos = content.find(end_tag, idx)
    if close_pos == -1:
        return content
    block_end = close_pos + len(end_tag)
    # Include trailing newline
    if block_end < len(content) and content[block_end] == '\n':
        block_end += 1

    return content[:block_start] + content[block_end:]


def remove_injection(content):
    """Remove all Pepper-injected env vars and pre-actions."""
    for key in ["DYLD_INSERT_LIBRARIES", "PEPPER_ADAPTER"]:
        content = remove_block(content, f'key = "{key}"', "</EnvironmentVariable>")
    content = remove_block(content, f'title = "{BUILD_MARKER}"', "</ExecutionAction>")
    return content


def inject_content(content, pepper_root, adapter):
    """Inject Pepper env vars and build pre-action into scheme content string."""
    if MARKER in content:
        return content
    content = inject_env_vars(content, pepper_root, adapter)
    if content is None:
        return None
    if BUILD_MARKER not in content:
        content = inject_build_preaction(content, pepper_root)
    return content


def setup_filter(scheme_path, pepper_root, adapter):
    """Configure git smudge/clean filter for transparent Pepper injection.

    After this, git sees the clean (no-Pepper) version in the index while
    the working copy has Pepper injected.  Legitimate scheme changes commit
    normally — no assume-unchanged / skip-worktree needed.
    """
    inject_script = os.path.abspath(__file__)

    smudge_cmd = (
        f'python3 "{inject_script}" --filter-smudge'
        f' --pepper-root "{pepper_root}" --adapter {adapter}'
    )
    clean_cmd = f'python3 "{inject_script}" --filter-clean'

    subprocess.run(["git", "config", "filter.pepper-scheme.smudge", smudge_cmd],
                   check=True, capture_output=True)
    subprocess.run(["git", "config", "filter.pepper-scheme.clean", clean_cmd],
                   check=True, capture_output=True)

    # Find the correct git dir (handles linked worktrees)
    git_dir = subprocess.run(
        ["git", "rev-parse", "--git-dir"],
        capture_output=True, text=True, check=True,
    ).stdout.strip()
    repo_root = subprocess.run(
        ["git", "rev-parse", "--show-toplevel"],
        capture_output=True, text=True, check=True,
    ).stdout.strip()

    rel_path = os.path.relpath(os.path.abspath(scheme_path), repo_root)
    attr_line = f"{rel_path} filter=pepper-scheme"

    # Write .git/info/attributes (per-worktree, untracked)
    attrs_dir = os.path.join(git_dir, "info")
    os.makedirs(attrs_dir, exist_ok=True)
    attrs_file = os.path.join(attrs_dir, "attributes")

    existing = ""
    if os.path.exists(attrs_file):
        with open(attrs_file) as f:
            existing = f.read()

    if attr_line not in existing:
        with open(attrs_file, "a") as f:
            if existing and not existing.endswith("\n"):
                f.write("\n")
            f.write(attr_line + "\n")

    # Clear stale assume-unchanged / skip-worktree flags
    for flag in ("--no-assume-unchanged", "--no-skip-worktree"):
        subprocess.run(
            ["git", "update-index", flag, rel_path],
            capture_output=True,
        )

    # Inject the current working copy (smudge doesn't run retroactively)
    with open(scheme_path) as f:
        content = f.read()

    injected = inject_content(content, pepper_root, adapter)
    if injected and injected != content:
        with open(scheme_path, "w") as f:
            f.write(injected)

    print(f"Configured smudge/clean filter for {rel_path}")
    print(f"  Working copy: Pepper injected")
    print(f"  Git index: clean (no Pepper)")


def main():
    parser = argparse.ArgumentParser(description="Inject Pepper into Xcode scheme")
    parser.add_argument("scheme", nargs="?", help="Path to .xcscheme file")
    parser.add_argument("--pepper-root", help="Pepper project root (auto-detected)")
    parser.add_argument("--adapter", default="fi", help="Adapter type (default: fi)")
    parser.add_argument("--remove", action="store_true", help="Remove injection")
    parser.add_argument("--setup-filter", action="store_true",
                        help="Configure git smudge/clean filter (replaces assume-unchanged)")
    parser.add_argument("--filter-clean", action="store_true",
                        help="Git clean filter: strip injection (stdin → stdout)")
    parser.add_argument("--filter-smudge", action="store_true",
                        help="Git smudge filter: add injection (stdin → stdout)")
    args = parser.parse_args()

    # --- Filter modes (stdin → stdout, no file path needed) ---

    if args.filter_clean:
        sys.stdout.write(remove_injection(sys.stdin.read()))
        return

    if args.filter_smudge:
        pepper_root = args.pepper_root or detect_pepper_root()
        content = sys.stdin.read()
        injected = inject_content(content, pepper_root, args.adapter)
        sys.stdout.write(injected if injected else content)
        return

    # --- File-based modes (require scheme path) ---

    if not args.scheme:
        parser.error("scheme path is required (unless using --filter-clean/--filter-smudge)")

    pepper_root = args.pepper_root or detect_pepper_root()
    scheme_path = os.path.expanduser(args.scheme)

    if not os.path.isfile(scheme_path):
        print(f"ERROR: Scheme not found: {scheme_path}", file=sys.stderr)
        sys.exit(1)

    if args.setup_filter:
        setup_filter(scheme_path, pepper_root, args.adapter)
        return

    with open(scheme_path) as f:
        content = f.read()

    if args.remove:
        content = remove_injection(content)
        with open(scheme_path, "w") as f:
            f.write(content)
        print(f"Removed Pepper injection from {scheme_path}")
        return

    # Check if already injected
    if MARKER in content:
        print(f"Already injected — skipping {scheme_path}")
        return

    content = inject_content(content, pepper_root, args.adapter)
    if content is None:
        sys.exit(1)

    with open(scheme_path, "w") as f:
        f.write(content)

    print(f"Injected Pepper into {scheme_path}")
    print(f"  dylib: {pepper_root}/build/Pepper.framework/Pepper")
    print(f"  adapter: {args.adapter}")


if __name__ == "__main__":
    main()

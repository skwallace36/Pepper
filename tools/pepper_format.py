"""
Pepper formatting utilities — ANSI color helpers and look output formatting.

Used by pepper-mcp, pepper-ctl, and pepper-stream.
"""
from __future__ import annotations

import re

# SF Symbol private-use-area characters (U+100000–U+100FFF) that appear in
# combined accessibility labels. Strip them to keep output readable.
_SF_SYMBOL_RE = re.compile(r'[\U00100000-\U00100FFF]+')


def _strip_sf_symbols(text: str) -> str:
    """Remove SF Symbol characters and collapse whitespace."""
    cleaned = _SF_SYMBOL_RE.sub('', text).strip()
    return re.sub(r'\s+', ' ', cleaned)

# ---------------------------------------------------------------------------
# ANSI color helpers
# ---------------------------------------------------------------------------

USE_COLOR = False  # Callers set this; default off (safe for MCP / piped output)


def _c(code, text):
    if USE_COLOR:
        return f"\033[{code}m{text}\033[0m"
    return str(text)


def green(text):
    return _c("32", text)


def red(text):
    return _c("31", text)


def yellow(text):
    return _c("33", text)


def cyan(text):
    return _c("36", text)


def magenta(text):
    return _c("35", text)


def blue(text):
    return _c("34", text)


def dim(text):
    return _c("2", text)


def bold(text):
    return _c("1", text)


def white(text):
    return _c("37", text)


# ---------------------------------------------------------------------------
# format_look — compact screen summary from introspect mode:map response
# ---------------------------------------------------------------------------

_TYPE_ABBREV = {
    "button": "btn", "staticText": "txt", "textField": "fld",
    "switch": "tog", "segment": "seg", "cell": "cell",
    "slider": "sld", "image": "img",
}

_HEURISTIC_BADGES = {
    "toggle": "toggle", "slider": "sld", "checkbox": "chk",
    "tab_button": "tab", "radio_option": "opti", "segment": "seg",
}


def format_look(resp: dict) -> str:
    """Format introspect mode:map response as compact readable summary.

    Respects the module-level USE_COLOR flag for ANSI color output.
    """
    import json

    if resp.get("status") != "ok":
        return json.dumps(resp, indent=2)

    data = resp.get("data", {})
    screen = data.get("screen", "unknown")
    rows = data.get("rows", [])
    ni = data.get("non_interactive", [])

    # Viewport bounds for filtering off-screen elements
    screen_size = data.get("screen_size", {})
    vw = screen_size.get("w", 0)
    vh = screen_size.get("h", 0)

    def in_viewport(element: dict) -> bool:
        if not vw or not vh:
            return True
        cx, cy = element.get("center", [0, 0])
        if not (0 <= cx <= vw and 0 <= cy <= vh):
            return False
        sc = element.get("scroll_context", {})
        return not (sc and sc.get("visible_in_viewport") is False)

    # Filter to viewport-visible elements
    filtered_rows = []
    for row in rows:
        elements = [e for e in row.get("elements", []) if in_viewport(e)]
        if elements:
            filtered_rows.append({**row, "elements": elements})
    rows = filtered_rows
    ni = [e for e in ni if in_viewport(e)]

    # Simplify screen name
    m = re.search(r'<(_\w+_view)', screen)
    if m:
        screen = m.group(1)
    elif len(screen) > 60:
        screen = screen[:57] + "..."

    interactive_count = sum(len(r.get("elements", [])) for r in rows)
    mem = data.get("memory_mb")
    nav_title = data.get("nav_title", "")

    # Detect active tab (bottom-of-screen selected element)
    tab_info = ""
    for row in rows:
        for e in row.get("elements", []):
            traits = e.get("traits", [])
            label = e.get("label", "")
            if "selected" in traits and e.get("center", [0, 0])[1] > 700:
                tab_info = label
                break
        if tab_info:
            break

    # Header
    header = f"Screen: {bold(screen)}"
    if tab_info:
        header += f" | Tab: {bold(tab_info)}"
    header += f"  ({interactive_count} interactive, {len(ni)} text)"
    if nav_title:
        header += f"  Title: \"{nav_title}\""
    if mem:
        header += f"  [{mem:.0f}MB]"
    lines = [header]

    # Interactive rows
    prev_y_max = -1
    for row in rows:
        elements = row.get("elements", [])
        if not elements:
            continue
        y_range = row.get("y_range", [0, 0])
        # Add a blank line only when there's a vertical gap between row groups
        if prev_y_max >= 0 and y_range[0] - prev_y_max > 40:
            lines.append("")
        prev_y_max = y_range[1]
        lines.append(dim(f"[y={y_range[0]}-{y_range[1]}]"))

        for e in elements:
            etype = e.get("type", "?")
            label = _strip_sf_symbols(e.get("label", ""))
            tap_cmd = e.get("tap_cmd", "")
            icon = e.get("icon_name", "")
            heuristic = e.get("heuristic", "")
            badge = e.get("badge", "") or _HEURISTIC_BADGES.get(heuristic, "")
            traits = e.get("traits", [])
            suggested = e.get("suggested_tap", "")

            # Status flags
            flags = ""
            if e.get("selected") or "selected" in traits:
                flags += green(" [selected]")
            toggle_state = e.get("toggle_state", "")
            if toggle_state:
                flags += green(f" [{toggle_state}]") if toggle_state == "on" else yellow(f" [{toggle_state}]")
            if "notEnabled" in traits:
                flags += yellow(" [disabled]")
            if not e.get("hit_reachable", True):
                flags += red(" [blocked]")

            # Element description
            idx = e.get("index")
            value = e.get("value", "")
            if icon and not label:
                desc = f"[{icon}]"
            elif label:
                disp = label if len(label) <= 50 else label[:47] + "..."
                idx_suffix = f" [{idx}]" if idx else ""
                val_suffix = f" = {value}" if value and etype in ("textField", "searchField", "textView") else ""
                desc = f'"{disp}"{idx_suffix}{val_suffix}'
            else:
                desc = f"({heuristic or etype})"

            # Type prefix
            prefix = badge if badge else _TYPE_ABBREV.get(etype, etype[:4])

            # Tap instruction
            if tap_cmd == "text" and label:
                if idx:
                    tap = f'tap text:"{label}" index:{idx}'
                elif len(label) <= 50:
                    tap = f'tap text:"{label}"'
                else:
                    # Use truncated prefix — tap handler uses substring matching
                    # (localizedCaseInsensitiveContains) so a prefix is enough.
                    prefix = label[:47] + "..."
                    tap = f'tap text:"{prefix}"'
            elif tap_cmd == "icon_name" and (icon or suggested):
                tap = f"tap icon:{icon or suggested}"
            elif tap_cmd == "heuristic" and (heuristic or suggested):
                tap = f"tap heuristic:{suggested or heuristic}"
            else:
                cx, cy = e.get("center", [0, 0])
                tap = f"tap point:{cx},{cy}"

            lines.append(f"  {cyan(prefix):>8s}  {desc:<52s} → {tap}{flags}")

    # Non-interactive text
    if ni:
        lines.append(dim("--- text ---"))
        for e in ni:
            label = _strip_sf_symbols(e.get("label", ""))
            if label:
                lines.append(f"  {dim(label)}")

    # Leak warnings
    leaks = data.get("leaks", [])
    if leaks:
        lines.append("--- leaks detected ---")
        for leak in leaks[:10]:
            cls = leak.get("class", "?")
            before = leak.get("before", 0)
            after = leak.get("after", 0)
            delta = leak.get("delta", after - before)
            lines.append(f"  {cls}: {before} → {after} (+{delta})")

    return "\n".join(lines)


# ---------------------------------------------------------------------------
# format_look_slim — agent-optimised output: no y-coords, tap commands kept
# ---------------------------------------------------------------------------


def format_look_slim(resp: dict) -> str:
    """Format introspect mode:map response as slim stateless output for agents.

    Compared to format_look:
    - Flat element list — no y-coordinate group headers or blank separators
    - Coordinate-free tap commands: prefers text/icon/heuristic over point:x,y
    - Shorter status flags ([sel] not [selected])
    - Collapsing single-child groups is implicit (no per-group header overhead)

    Unlike compact mode, tap commands are always included and there is no
    diffing state — every call returns the full current screen.
    """
    import json

    if resp.get("status") != "ok":
        return json.dumps(resp, indent=2)

    data = resp.get("data", {})
    screen = data.get("screen", "unknown")
    rows = data.get("rows", [])
    ni = data.get("non_interactive", [])

    screen_size = data.get("screen_size", {})
    vw = screen_size.get("w", 0)
    vh = screen_size.get("h", 0)

    def in_viewport(element: dict) -> bool:
        if not vw or not vh:
            return True
        cx, cy = element.get("center", [0, 0])
        if not (0 <= cx <= vw and 0 <= cy <= vh):
            return False
        sc = element.get("scroll_context", {})
        return not (sc and sc.get("visible_in_viewport") is False)

    # Flatten rows to a single ordered list, viewport-filtered
    all_interactive = []
    for row in rows:
        for e in row.get("elements", []):
            if in_viewport(e):
                all_interactive.append(e)
    ni = [e for e in ni if in_viewport(e)]

    # Simplify screen name
    m = re.search(r'<(_\w+_view)', screen)
    if m:
        screen = m.group(1)
    elif len(screen) > 60:
        screen = screen[:57] + "..."

    nav_title = data.get("nav_title", "")
    mem = data.get("memory_mb")

    # Detect active tab (bottom-of-screen selected element)
    tab_info = ""
    for e in all_interactive:
        if "selected" in e.get("traits", []) and e.get("center", [0, 0])[1] > 700:
            tab_info = e.get("label", "")
            break

    header = f"Screen: {bold(screen)}"
    if tab_info:
        header += f" | Tab: {bold(tab_info)}"
    header += f"  ({len(all_interactive)} interactive, {len(ni)} text)"
    if nav_title:
        header += f'  Title: "{nav_title}"'
    if mem:
        header += f"  [{mem:.0f}MB]"
    lines = [header, ""]

    # System dialog warning
    dialog_data = data.get("system_dialog_blocking")
    if dialog_data:
        for d in dialog_data.get("dialogs", []):
            title = d.get("title", "")
            btn_str = ", ".join(str(b) for b in d.get("buttons", []))
            lines.append(f"  !! DIALOG: {title} [{btn_str}]")
        lines.append("")

    # Interactive elements — flat list, no y-range headers
    for e in all_interactive:
        etype = e.get("type", "?")
        label = e.get("label", "")
        tap_cmd = e.get("tap_cmd", "")
        icon = e.get("icon_name", "")
        heuristic = e.get("heuristic", "")
        badge = e.get("badge", "") or _HEURISTIC_BADGES.get(heuristic, "")
        traits = e.get("traits", [])
        suggested = e.get("suggested_tap", "")

        # Compact status flags
        flags = ""
        if e.get("selected") or "selected" in traits:
            flags += green(" [sel]")
        toggle_state = e.get("toggle_state", "")
        if toggle_state:
            flags += green(f" [{toggle_state}]") if toggle_state == "on" else yellow(f" [{toggle_state}]")
        if "notEnabled" in traits:
            flags += yellow(" [dis]")
        if not e.get("hit_reachable", True):
            flags += red(" [blocked]")

        # Element description
        idx = e.get("index")
        value = e.get("value", "")
        if icon and not label:
            desc = f"[{icon}]"
        elif label:
            disp = label if len(label) <= 50 else label[:47] + "..."
            idx_suffix = f" [{idx}]" if idx else ""
            val_suffix = f" = {value}" if value and etype in ("textField", "searchField", "textView") else ""
            desc = f'"{disp}"{idx_suffix}{val_suffix}'
        else:
            desc = f"({heuristic or etype})"

        prefix = badge if badge else _TYPE_ABBREV.get(etype, etype[:4])

        # Tap instruction — prefer coordinate-free forms
        if tap_cmd == "text" and label:
            lbl = label if len(label) <= 40 else label[:40] + "..."
            tap = f'tap text:"{lbl}"' + (f" index:{idx}" if idx else "")
        elif tap_cmd == "icon_name" and (icon or suggested):
            tap = f"tap icon:{icon or suggested}"
        elif tap_cmd == "heuristic" and (heuristic or suggested):
            tap = f"tap heuristic:{suggested or heuristic}"
        elif label:
            lbl = label if len(label) <= 40 else label[:40] + "..."
            tap = f'tap text:"{lbl}"' + (f" index:{idx}" if idx else "")
        elif icon:
            tap = f"tap icon:{icon}"
        elif heuristic or suggested:
            tap = f"tap heuristic:{suggested or heuristic}"
        else:
            cx, cy = e.get("center", [0, 0])
            tap = f"tap point:{cx},{cy}"

        lines.append(f"  {cyan(prefix):>8s}  {desc:<52s} → {tap}{flags}")

    # Non-interactive text
    if ni:
        lines.append("")
        lines.append(dim("--- text ---"))
        for e in ni:
            label = e.get("label", "")
            if label:
                lines.append(f"  {dim(label)}")

    # Leak warnings
    leaks = data.get("leaks", [])
    if leaks:
        lines.append("")
        lines.append("--- leaks ---")
        for leak in leaks[:5]:
            cls = leak.get("class", "?")
            delta = leak.get("delta", 0)
            lines.append(f"  {cls} (+{delta})")

    return "\n".join(lines)


# ---------------------------------------------------------------------------
# format_look_compact — slim output for agent sessions (omits coords, diffs)
# ---------------------------------------------------------------------------

# Module-level state for diffing across compact look calls.
_prev_compact_fingerprints: dict[str, str] = {}  # element_key -> state_fingerprint
_prev_compact_screen: str = ""
_prev_compact_text: set[str] = set()


def _element_key(e: dict) -> str:
    """Stable identity key for an element across look calls."""
    label = e.get("label", "")
    idx = e.get("index", "")
    etype = e.get("type", "")
    heuristic = e.get("heuristic", "")
    icon = e.get("icon_name", "")
    return f"{etype}|{label}|{idx}|{heuristic}|{icon}"


def _element_state(e: dict) -> str:
    """Mutable state fingerprint (value, selected, toggle, etc.)."""
    parts = []
    if e.get("selected"):
        parts.append("sel")
    if e.get("toggle_state"):
        parts.append(f"tog:{e['toggle_state']}")
    if e.get("value"):
        parts.append(f"val:{e['value']}")
    traits = e.get("traits", [])
    if "notEnabled" in traits:
        parts.append("disabled")
    if not e.get("hit_reachable", True):
        parts.append("blocked")
    return "|".join(parts)


def _compact_element_line(e: dict, prefix_char: str = " ") -> str:
    """Render one interactive element as a minimal line (no coords, no tap cmd)."""
    etype = e.get("type", "?")
    label = e.get("label", "")
    icon = e.get("icon_name", "")
    heuristic = e.get("heuristic", "")
    badge = _HEURISTIC_BADGES.get(heuristic, "")
    traits = e.get("traits", [])

    # Status flags
    flags = ""
    if e.get("selected") or "selected" in traits:
        flags += " [selected]"
    toggle_state = e.get("toggle_state", "")
    if toggle_state:
        flags += f" [{toggle_state}]"
    if "notEnabled" in traits:
        flags += " [disabled]"
    if not e.get("hit_reachable", True):
        flags += " [blocked]"

    # Element description
    idx = e.get("index")
    value = e.get("value", "")
    if icon and not label:
        desc = f"[{icon}]"
    elif label:
        disp = label if len(label) <= 50 else label[:47] + "..."
        idx_suffix = f" [{idx}]" if idx else ""
        val_suffix = (
            f" = {value}"
            if value and etype in ("textField", "searchField", "textView")
            else ""
        )
        desc = f'"{disp}"{idx_suffix}{val_suffix}'
    else:
        desc = f"({heuristic or etype})"

    type_abbrev = badge if badge else _TYPE_ABBREV.get(etype, etype[:4])
    return f"{prefix_char} {type_abbrev:>6s}  {desc}{flags}"


def format_look_compact(resp: dict) -> str:
    """Format introspect mode:map response as a slim diff for agent sessions.

    Compared to format_look:
    - Omits y-coordinates and frame/center data
    - Omits tap commands (agents use ``tap text:"..."`` directly)
    - Diffs against previous call — only shows changed/new/removed elements
    - Reduces context consumption by 60-70%
    """
    global _prev_compact_fingerprints, _prev_compact_screen, _prev_compact_text
    import json

    if resp.get("status") != "ok":
        return json.dumps(resp, indent=2)

    data = resp.get("data", {})
    screen = data.get("screen", "unknown")
    rows = data.get("rows", [])
    ni = data.get("non_interactive", [])

    # Viewport filter (same as format_look)
    screen_size = data.get("screen_size", {})
    vw = screen_size.get("w", 0)
    vh = screen_size.get("h", 0)

    def in_viewport(element: dict) -> bool:
        if not vw or not vh:
            return True
        cx, cy = element.get("center", [0, 0])
        if not (0 <= cx <= vw and 0 <= cy <= vh):
            return False
        sc = element.get("scroll_context", {})
        return not (sc and sc.get("visible_in_viewport") is False)

    # Flatten interactive elements from rows, filter viewport
    all_interactive = []
    for row in rows:
        for e in row.get("elements", []):
            if in_viewport(e):
                all_interactive.append(e)
    ni = [e for e in ni if in_viewport(e)]

    # Simplify screen name
    m = re.search(r'<(_\w+_view)', screen)
    if m:
        screen = m.group(1)
    elif len(screen) > 60:
        screen = screen[:57] + "..."

    nav_title = data.get("nav_title", "")
    mem = data.get("memory_mb")

    # Build current fingerprints
    cur_fingerprints: dict[str, str] = {}
    cur_elements: dict[str, dict] = {}
    for e in all_interactive:
        key = _element_key(e)
        cur_fingerprints[key] = _element_state(e)
        cur_elements[key] = e

    cur_text = {e.get("label", "") for e in ni if e.get("label")}

    # Determine if screen changed (full reset on screen change)
    screen_changed = (screen != _prev_compact_screen)

    # Diff interactive elements
    prev_fp = _prev_compact_fingerprints if not screen_changed else {}
    prev_text = _prev_compact_text if not screen_changed else set()

    added_keys = set(cur_fingerprints) - set(prev_fp)
    removed_keys = set(prev_fp) - set(cur_fingerprints)
    changed_keys = {
        k for k in set(cur_fingerprints) & set(prev_fp)
        if cur_fingerprints[k] != prev_fp[k]
    }
    unchanged_count = len(cur_fingerprints) - len(added_keys) - len(changed_keys)

    new_text = cur_text - prev_text
    removed_text = prev_text - cur_text
    unchanged_text_count = len(cur_text) - len(new_text)

    # Update stored state
    _prev_compact_fingerprints = cur_fingerprints
    _prev_compact_screen = screen
    _prev_compact_text = cur_text

    # Build output
    interactive_count = len(all_interactive)
    header = f"Screen: {bold(screen)}"
    if nav_title:
        header += f'  Title: "{nav_title}"'
    header += f"  ({interactive_count} interactive, {len(ni)} text)"
    if mem:
        header += f"  [{mem:.0f}MB]"
    lines = [header]

    # System dialog warning (compact but present)
    dialog_data = data.get("system_dialog_blocking")
    if dialog_data:
        dialogs = dialog_data.get("dialogs", [])
        for d in dialogs:
            title = d.get("title", "")
            buttons = d.get("buttons", [])
            btn_str = ", ".join(str(b) for b in buttons) if buttons else ""
            lines.append(f"  !! DIALOG: {title} [{btn_str}]")

    # Interactive elements
    if screen_changed or not prev_fp:
        # First call or screen change: show all elements
        if all_interactive:
            lines.append("")
            for e in all_interactive:
                lines.append(_compact_element_line(e))
    else:
        # Diff mode: only show changes
        show_keys = added_keys | changed_keys
        if show_keys or removed_keys:
            lines.append("")
            lines.append(
                dim(f"--- {len(show_keys)} changed, {unchanged_count} unchanged ---")
            )
            # Show added/changed elements in original order
            for e in all_interactive:
                key = _element_key(e)
                if key in added_keys:
                    lines.append(_compact_element_line(e, "+"))
                elif key in changed_keys:
                    lines.append(_compact_element_line(e, "~"))
            # Show removed
            for key in sorted(removed_keys):
                parts = key.split("|")
                label = parts[1] if len(parts) > 1 and parts[1] else parts[0]
                lines.append(f"- (removed: {label})")
        else:
            lines.append(dim("  (no interactive changes)"))

    # Non-interactive text
    if screen_changed or not prev_text:
        if ni:
            lines.append("")
            lines.append(dim("--- text ---"))
            for e in ni:
                label = e.get("label", "")
                if label:
                    lines.append(f"  {dim(label)}")
    else:
        text_changes = new_text | removed_text
        if text_changes:
            lines.append("")
            lines.append(
                dim(f"--- text: {len(new_text)} new, {len(removed_text)} gone, {unchanged_text_count} unchanged ---")
            )
            for t in sorted(new_text):
                lines.append(f"  + {dim(t)}")
            for t in sorted(removed_text):
                lines.append(f"  - {dim(t)}")
        else:
            lines.append(dim("  (no text changes)"))

    # Leaks (always show)
    leaks = data.get("leaks", [])
    if leaks:
        lines.append("")
        lines.append("--- leaks ---")
        for leak in leaks[:5]:
            cls = leak.get("class", "?")
            delta = leak.get("delta", 0)
            lines.append(f"  {cls} (+{delta})")

    return "\n".join(lines)

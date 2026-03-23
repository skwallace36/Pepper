"""
Pepper formatting utilities — ANSI color helpers and look output formatting.

Used by pepper-mcp, pepper-ctl, and pepper-stream.
"""

import re

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
    lines = [header, ""]

    # Interactive rows
    for row in rows:
        elements = row.get("elements", [])
        if not elements:
            continue
        y_range = row.get("y_range", [0, 0])
        lines.append(dim(f"[y={y_range[0]}-{y_range[1]}]"))

        for e in elements:
            etype = e.get("type", "?")
            label = e.get("label", "")
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
                elif len(label) <= 40:
                    tap = f'tap text:"{label}"'
                else:
                    tap = f'tap point:{e["center"][0]},{e["center"][1]}'
            elif tap_cmd == "icon_name" and (icon or suggested):
                tap = f"tap icon:{icon or suggested}"
            elif tap_cmd == "heuristic" and (heuristic or suggested):
                tap = f"tap heuristic:{suggested or heuristic}"
            else:
                cx, cy = e.get("center", [0, 0])
                tap = f"tap point:{cx},{cy}"

            lines.append(f"  {cyan(prefix):>8s}  {desc:<52s} → {tap}{flags}")
        lines.append("")

    # Non-interactive text
    if ni:
        lines.append(dim("--- text ---"))
        for e in ni:
            label = e.get("label", "")
            if label:
                lines.append(f"  {dim(label)}")

    # Leak warnings
    leaks = data.get("leaks", [])
    if leaks:
        lines.append("")
        lines.append("--- leaks detected ---")
        for leak in leaks[:10]:
            cls = leak.get("class", "?")
            before = leak.get("before", 0)
            after = leak.get("after", 0)
            delta = leak.get("delta", after - before)
            lines.append(f"  {cls}: {before} → {after} (+{delta})")

    return "\n".join(lines)

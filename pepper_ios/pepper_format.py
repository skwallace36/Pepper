"""
Pepper formatting utilities — ANSI color helpers and look output formatting.

Used by pepper-mcp, pepper-ctl, and pepper-stream.
"""

from __future__ import annotations

import re

from .pepper_common import json_dumps

# SF Symbol private-use-area characters (U+100000–U+100FFF) that appear in
# combined accessibility labels. Strip them to keep output readable.
_SF_SYMBOL_RE = re.compile(r"[\U00100000-\U00100FFF]+")


def _strip_sf_symbols(text: str) -> str:
    """Remove SF Symbol characters and collapse whitespace."""
    cleaned = _SF_SYMBOL_RE.sub("", text).strip()
    return re.sub(r"\s+", " ", cleaned)


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
    "button": "btn",
    "staticText": "txt",
    "textField": "fld",
    "switch": "tog",
    "segment": "seg",
    "cell": "cell",
    "slider": "sld",
    "image": "img",
}

_HEURISTIC_BADGES = {
    "toggle": "toggle",
    "slider": "sld",
    "checkbox": "chk",
    "tab_button": "tab",
    "radio_option": "opti",
    "segment": "seg",
}


def _format_ocr_line(item: dict) -> str:
    """Render one OCR result: ocr  "text"  point:x,y  conf:0.92"""
    text = item.get("text", "")
    disp = text if len(text) <= 50 else text[:47] + "..."
    cx, cy = item.get("center", [0, 0])
    conf = item.get("confidence", 0.0)
    return f'  {"ocr":>6s}  "{disp}"  point:{cx},{cy}  conf:{conf:.2f}'


def _group_text_by_container(all_interactive, ni, screen_size=None):
    """Group non-interactive text under their smallest containing interactive element.

    Returns (ordered_groups, grouped, ungrouped) where:
    - ordered_groups: container labels in first-appearance order
    - grouped: dict mapping container label -> list of text strings
    - ungrouped: list of text strings not inside any container
    """
    if not ni:
        return [], {}, []

    # Skip containers larger than 50% of screen area
    max_area = float("inf")
    if screen_size:
        sw = screen_size.get("w", 0)
        sh = screen_size.get("h", 0)
        if sw and sh:
            max_area = sw * sh * 0.5

    # Collect labeled interactive elements as potential containers
    containers = []
    for e in all_interactive:
        label = _strip_sf_symbols(e.get("label", ""))
        if not label:
            continue
        frame = e.get("frame", [0, 0, 0, 0])
        if len(frame) != 4:
            continue
        x, y, w, h = frame
        area = w * h
        if area <= 0 or area > max_area:
            continue
        containers.append((label, x, y, w, h, area))

    if not containers:
        # No containers — return all text ungrouped
        texts = [_strip_sf_symbols(e.get("label", "")) for e in ni]
        return [], {}, [t for t in texts if t]

    grouped: dict[str, list[str]] = {}
    ungrouped: list[str] = []
    ordered_groups: list[str] = []

    for e in ni:
        text = _strip_sf_symbols(e.get("label", ""))
        if not text:
            continue
        cx, cy = e.get("center", [0, 0])

        best_label = None
        best_area = float("inf")

        for clabel, fx, fy, fw, fh, area in containers:
            if fx <= cx <= fx + fw and fy <= cy <= fy + fh and area < best_area:
                best_label = clabel
                best_area = area

        if best_label and text != best_label:
            if best_label not in grouped:
                ordered_groups.append(best_label)
                grouped[best_label] = []
            grouped[best_label].append(text)
        else:
            ungrouped.append(text)

    return ordered_groups, grouped, ungrouped


def _render_grouped_text(ordered_groups, grouped, ungrouped, dim_fn):
    """Render grouped text lines for the --- text --- section."""
    lines = []
    for glabel in ordered_groups:
        lines.append(f"  {dim_fn(glabel + ':')}")
        for text in grouped[glabel]:
            lines.append(f"    {dim_fn(text)}")
    for text in ungrouped:
        lines.append(f"  {dim_fn(text)}")
    return lines


def _scroll_indicator_lines(
    data: dict,
    total_interactive: int,
    visible_interactive: int,
    total_ni: int,
    visible_ni: int,
) -> list[str]:
    """Build scroll indicator lines when off-screen elements exist.

    Returns a list of formatted lines (may be empty if nothing is scrollable).
    """
    hidden_interactive = total_interactive - visible_interactive
    hidden_ni = total_ni - visible_ni
    hidden_total = hidden_interactive + hidden_ni
    if hidden_total == 0:
        return []

    containers = data.get("scroll_containers", [])
    if not containers:
        # No container metadata — just report hidden count
        parts = []
        if hidden_interactive:
            parts.append(f"{hidden_interactive} interactive")
        if hidden_ni:
            parts.append(f"{hidden_ni} text")
        return [dim(f"  >> {' + '.join(parts)} off-screen — scroll to reveal")]

    # Use the largest (primary) scroll container for position info
    primary = max(containers, key=lambda c: (
        c.get("visible_size", {}).get("w", 0)
        * c.get("visible_size", {}).get("h", 0)
    ))
    direction = primary.get("direction", "vertical")
    content = primary.get("content_size", {})
    visible = primary.get("visible_size", {})
    offset = primary.get("offset", {})

    # Compute scroll position for the primary axis
    hints = []
    if direction in ("vertical", "both"):
        content_h = content.get("h", 0)
        visible_h = visible.get("h", 0)
        offset_y = offset.get("y", 0)
        scrollable = content_h - visible_h
        if scrollable > 0:
            if offset_y < 10:
                hints.append("more content below")
            elif scrollable - offset_y < 10:
                hints.append("more content above")
            else:
                pct = int(100 * offset_y / scrollable)
                hints.append(f"scrolled {pct}% — content above & below")
    if direction in ("horizontal", "both"):
        content_w = content.get("w", 0)
        visible_w = visible.get("w", 0)
        offset_x = offset.get("x", 0)
        scrollable = content_w - visible_w
        if scrollable > 0:
            if offset_x < 10:
                hints.append("more content right")
            elif scrollable - offset_x < 10:
                hints.append("more content left")
            else:
                pct = int(100 * offset_x / scrollable)
                hints.append(f"scrolled {pct}% horizontally")

    parts = []
    if hidden_interactive:
        parts.append(f"{hidden_interactive} interactive")
    if hidden_ni:
        parts.append(f"{hidden_ni} text")
    hidden_str = f"{' + '.join(parts)} off-screen"
    hint_str = f" ({'; '.join(hints)})" if hints else ""

    return [dim(f"  >> {hidden_str}{hint_str} — scroll to reveal")]


def filter_raw(resp: dict, filter_type: str | None, fields_csv: str | None) -> dict:
    """Post-process raw look response: filter elements by type and/or project fields.

    Args:
        resp: Full JSON response from the dylib.
        filter_type: Case-insensitive substring match against element ``type``.
        fields_csv: Comma-separated field names to keep per element.
    """
    import copy

    resp = copy.deepcopy(resp)
    data = resp.get("data", resp)

    type_needle = filter_type.lower() if filter_type else None
    field_set = {f.strip() for f in fields_csv.split(",") if f.strip()} if fields_csv else None

    def _matches(el: dict) -> bool:
        if type_needle is None:
            return True
        return type_needle in (el.get("type") or "").lower()

    def _project(el: dict) -> dict:
        if field_set is None:
            return el
        return {k: v for k, v in el.items() if k in field_set}

    if "rows" in data:
        for row in data["rows"]:
            if "elements" in row:
                row["elements"] = [_project(e) for e in row["elements"] if _matches(e)]
        data["rows"] = [r for r in data["rows"] if r.get("elements")]

    if "non_interactive" in data:
        data["non_interactive"] = [_project(e) for e in data["non_interactive"] if _matches(e)]

    total = sum(len(r.get("elements", [])) for r in data.get("rows", []))
    total += len(data.get("non_interactive", []))
    data["element_count"] = total

    return resp


def format_look(resp: dict) -> str:
    """Format introspect mode:map response as compact readable summary.

    Respects the module-level USE_COLOR flag for ANSI color output.
    """
    if resp.get("status") != "ok":
        return json_dumps(resp)

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

    # Count totals before filtering (for scroll indicators)
    total_interactive = sum(len(r.get("elements", [])) for r in rows)
    total_ni = len(ni)

    # Filter to viewport-visible elements
    filtered_rows = []
    for row in rows:
        elements = [e for e in row.get("elements", []) if in_viewport(e)]
        if elements:
            filtered_rows.append({**row, "elements": elements})
    rows = filtered_rows
    ni = [e for e in ni if in_viewport(e)]

    # Simplify screen name
    m = re.search(r"<(_\w+_view)", screen)
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
        header += f'  Title: "{nav_title}"'
    if mem:
        header += f"  [{mem:.0f}MB]"
    lines = [header]

    # System dialog warning
    dialog_data = data.get("system_dialog_blocking")
    if dialog_data:
        for d in dialog_data.get("dialogs", []):
            title = d.get("title", "")
            buttons = d.get("buttons", [])
            btn_str = ", ".join(str(b) for b in buttons)
            lines.append(f"  !! SYSTEM DIALOG: {title} [{btn_str}]")
            for btn in buttons:
                lines.append(f'       → dialog dismiss button="{btn}"')
        lines.append("       → dialog dismiss_system (auto-detect and dismiss)")
        lines.append("")

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
                idx_suffix = f" [{idx}]" if idx else ""
                desc = f"[{icon}]{idx_suffix}"
            elif label:
                disp = label if len(label) <= 50 else label[:47] + "..."
                idx_suffix = f" [{idx}]" if idx else ""
                val_suffix = f" = {value}" if value and etype in ("textField", "searchField", "textView") else ""
                desc = f'"{disp}"{idx_suffix}{val_suffix}'
            else:
                idx_suffix = f" [{idx}]" if idx else ""
                desc = f"({heuristic or etype}){idx_suffix}"

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
                tap = f"tap icon:{icon or suggested}" + (f" index:{idx}" if idx else "")
            elif tap_cmd == "heuristic" and (heuristic or suggested):
                tap = f"tap heuristic:{suggested or heuristic}" + (f" index:{idx}" if idx else "")
            else:
                cx, cy = e.get("center", [0, 0])
                tap = f"tap point:{cx},{cy}"

            lines.append(f"  {cyan(prefix):>8s}  {desc:<52s} → {tap}{flags}")

    # Non-interactive text (grouped under containing interactive elements)
    if ni:
        lines.append(dim("--- text ---"))
        all_int = [e for row in rows for e in row.get("elements", [])]
        ordered, grouped, ungrouped = _group_text_by_container(
            all_int, ni, data.get("screen_size"))
        lines.extend(_render_grouped_text(ordered, grouped, ungrouped, dim))

    # OCR-only text
    ocr_results = data.get("ocr_results", [])
    if ocr_results:
        lines.append(dim("── ocr-only text ──"))
        for item in ocr_results:
            lines.append(_format_ocr_line(item))

    # Leak warnings (only significant — minor jitter is filtered at the dylib level)
    leaks = data.get("leaks", [])
    if leaks:
        lines.append("--- leaks detected ---")
        for leak in leaks[:10]:
            cls = leak.get("class", "?")
            before = leak.get("before", 0)
            after = leak.get("after", 0)
            delta = leak.get("delta", after - before)
            suffix = ""
            if leak.get("sustained"):
                streak = leak.get("streak", 0)
                suffix = f" (growing for {streak} observations)"
            lines.append(f"  {cls}: {before} → {after} (+{delta}){suffix}")

    # Scroll indicators — surface hidden off-screen content
    visible_interactive = sum(len(r.get("elements", [])) for r in rows)
    lines.extend(_scroll_indicator_lines(
        data, total_interactive, visible_interactive, total_ni, len(ni)))

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
    if resp.get("status") != "ok":
        return json_dumps(resp)

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

    # Count totals before filtering (for scroll indicators)
    total_interactive = sum(len(r.get("elements", [])) for r in rows)
    total_ni = len(ni)

    # Flatten rows to a single ordered list, viewport-filtered
    all_interactive = []
    for row in rows:
        for e in row.get("elements", []):
            if in_viewport(e):
                all_interactive.append(e)
    ni = [e for e in ni if in_viewport(e)]

    screen = _normalize_screen(screen)

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
            buttons = d.get("buttons", [])
            btn_str = ", ".join(str(b) for b in buttons)
            lines.append(f"  !! SYSTEM DIALOG: {title} [{btn_str}]")
            for btn in buttons:
                lines.append(f'       → dialog dismiss button="{btn}"')
        lines.append("       → dialog dismiss_system (auto-detect and dismiss)")
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
            idx_suffix = f" [{idx}]" if idx else ""
            desc = f"[{icon}]{idx_suffix}"
        elif label:
            disp = label if len(label) <= 50 else label[:47] + "..."
            idx_suffix = f" [{idx}]" if idx else ""
            val_suffix = f" = {value}" if value and etype in ("textField", "searchField", "textView") else ""
            desc = f'"{disp}"{idx_suffix}{val_suffix}'
        else:
            idx_suffix = f" [{idx}]" if idx else ""
            desc = f"({heuristic or etype}){idx_suffix}"

        prefix = badge if badge else _TYPE_ABBREV.get(etype, etype[:4])

        # Tap instruction — prefer coordinate-free forms
        if tap_cmd == "text" and label:
            lbl = label if len(label) <= 40 else label[:40] + "..."
            tap = f'tap text:"{lbl}"' + (f" index:{idx}" if idx else "")
        elif tap_cmd == "icon_name" and (icon or suggested):
            tap = f"tap icon:{icon or suggested}" + (f" index:{idx}" if idx else "")
        elif tap_cmd == "heuristic" and (heuristic or suggested):
            tap = f"tap heuristic:{suggested or heuristic}" + (f" index:{idx}" if idx else "")
        elif label:
            lbl = label if len(label) <= 40 else label[:40] + "..."
            tap = f'tap text:"{lbl}"' + (f" index:{idx}" if idx else "")
        elif icon:
            tap = f"tap icon:{icon}" + (f" index:{idx}" if idx else "")
        elif heuristic or suggested:
            tap = f"tap heuristic:{suggested or heuristic}" + (f" index:{idx}" if idx else "")
        else:
            cx, cy = e.get("center", [0, 0])
            tap = f"tap point:{cx},{cy}"

        lines.append(f"  {cyan(prefix):>8s}  {desc:<52s} → {tap}{flags}")

    # Non-interactive text (grouped under containing interactive elements)
    if ni:
        lines.append("")
        lines.append(dim("--- text ---"))
        ordered, grouped, ungrouped = _group_text_by_container(
            all_interactive, ni, data.get("screen_size"))
        lines.extend(_render_grouped_text(ordered, grouped, ungrouped, dim))

    # OCR-only text
    ocr_results = data.get("ocr_results", [])
    if ocr_results:
        lines.append("")
        lines.append(dim("── ocr-only text ──"))
        for item in ocr_results:
            text = item.get("text", "")
            disp = text if len(text) <= 50 else text[:47] + "..."
            cx, cy = item.get("center", [0, 0])
            conf = item.get("confidence", 0.0)
            lines.append(f'  [ocr]  "{disp}"  point:{cx},{cy}  conf:{conf:.2f}')

    # Leak warnings (only significant — minor jitter filtered at dylib level)
    leaks = data.get("leaks", [])
    if leaks:
        lines.append("")
        lines.append("--- leaks ---")
        for leak in leaks[:5]:
            cls = leak.get("class", "?")
            delta = leak.get("delta", 0)
            suffix = " (sustained)" if leak.get("sustained") else ""
            lines.append(f"  {cls} (+{delta}){suffix}")

    # Scroll indicators — surface hidden off-screen content
    lines.extend(_scroll_indicator_lines(
        data, total_interactive, len(all_interactive), total_ni, len(ni)))

    return "\n".join(lines)


# ---------------------------------------------------------------------------
# Screen name normalization (shared by slim + compact formatters)
# ---------------------------------------------------------------------------

# Hex memory addresses embedded in UIKit class descriptions (e.g.,
# "<UINavigationController: 0x7fb5a2d0c3e0>").  These change between calls
# even when the screen hasn't actually changed.
_HEX_ADDR_RE = re.compile(r":?\s*0x[0-9a-fA-F]+")


def _normalize_screen(screen: str) -> str:
    """Normalize a screen name for stable display and comparison.

    Strips memory addresses and other dynamic content so the same logical
    screen produces the same string across calls.
    """
    # Strip hex memory addresses
    screen = _HEX_ADDR_RE.sub("", screen)
    # Extract class name from angle-bracket descriptions (<ClassName ...>)
    m = re.search(r"<(\w+)", screen)
    if m:
        return m.group(1)
    # Extract private view names (_foo_view)
    m = re.search(r"(_\w+_view)", screen)
    if m:
        return m.group(1)
    if len(screen) > 60:
        return screen[:57] + "..."
    return screen.strip()


# ---------------------------------------------------------------------------
# format_look_compact — diff output for agent sessions
# ---------------------------------------------------------------------------

# Module-level state for diffing across compact look calls.
_prev_compact_fingerprints: dict[str, str] = {}  # element_key -> state_fingerprint
_prev_compact_screen: str = ""
_prev_compact_text: set[str] = set()
_prev_compact_ocr: set[str] = set()  # OCR text strings from previous call


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
    """Render one interactive element as a compact line with tap command."""
    etype = e.get("type", "?")
    label = e.get("label", "")
    icon = e.get("icon_name", "")
    heuristic = e.get("heuristic", "")
    badge = _HEURISTIC_BADGES.get(heuristic, "")
    traits = e.get("traits", [])

    # Status flags (short form, matching slim)
    flags = ""
    if e.get("selected") or "selected" in traits:
        flags += " [sel]"
    toggle_state = e.get("toggle_state", "")
    if toggle_state:
        flags += f" [{toggle_state}]"
    if "notEnabled" in traits:
        flags += " [dis]"
    if not e.get("hit_reachable", True):
        flags += " [blocked]"

    # Element description
    idx = e.get("index")
    value = e.get("value", "")
    if icon and not label:
        idx_suffix = f" [{idx}]" if idx else ""
        desc = f"[{icon}]{idx_suffix}"
    elif label:
        disp = label if len(label) <= 50 else label[:47] + "..."
        idx_suffix = f" [{idx}]" if idx else ""
        val_suffix = f" = {value}" if value and etype in ("textField", "searchField", "textView") else ""
        desc = f'"{disp}"{idx_suffix}{val_suffix}'
    else:
        idx_suffix = f" [{idx}]" if idx else ""
        desc = f"({heuristic or etype}){idx_suffix}"

    type_abbrev = badge if badge else _TYPE_ABBREV.get(etype, etype[:4])

    # Tap command — prefer coordinate-free forms
    tap_cmd = e.get("tap_cmd", "")
    suggested = e.get("suggested_tap", "")
    if tap_cmd == "text" and label:
        lbl = label if len(label) <= 40 else label[:40] + "..."
        tap = f'tap text:"{lbl}"' + (f" index:{idx}" if idx else "")
    elif tap_cmd == "icon_name" and (icon or suggested):
        tap = f"tap icon:{icon or suggested}" + (f" index:{idx}" if idx else "")
    elif tap_cmd == "heuristic" and (heuristic or suggested):
        tap = f"tap heuristic:{suggested or heuristic}" + (f" index:{idx}" if idx else "")
    elif label:
        lbl = label if len(label) <= 40 else label[:40] + "..."
        tap = f'tap text:"{lbl}"' + (f" index:{idx}" if idx else "")
    elif icon:
        tap = f"tap icon:{icon}" + (f" index:{idx}" if idx else "")
    elif heuristic or suggested:
        tap = f"tap heuristic:{suggested or heuristic}" + (f" index:{idx}" if idx else "")
    else:
        cx, cy = e.get("center", [0, 0])
        tap = f"tap point:{cx},{cy}"

    return f"{prefix_char} {type_abbrev:>6s}  {desc}{flags}  → {tap}"


def format_look_compact(resp: dict) -> str:
    """Format introspect mode:map response as a diff for agent sessions.

    Compared to format_look:
    - Omits y-coordinates and frame/center data
    - Includes tap commands (agents can act on what they see)
    - Diffs against previous call — only shows changed/new/removed elements
    - First call (or screen change) shows full element list
    - Subsequent calls show only what changed (added/changed/removed)
    """
    global _prev_compact_fingerprints, _prev_compact_screen, _prev_compact_text, _prev_compact_ocr

    if resp.get("status") != "ok":
        return json_dumps(resp)

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

    # Count totals before filtering (for scroll indicators)
    total_interactive = sum(len(r.get("elements", [])) for r in rows)
    total_ni = len(ni)

    # Flatten interactive elements from rows, filter viewport
    all_interactive = []
    for row in rows:
        for e in row.get("elements", []):
            if in_viewport(e):
                all_interactive.append(e)
    ni = [e for e in ni if in_viewport(e)]

    screen = _normalize_screen(screen)

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

    # OCR results
    ocr_results = data.get("ocr_results", [])
    cur_ocr = {item.get("text", "") for item in ocr_results if item.get("text")}

    # Determine if screen changed (full reset on screen change)
    screen_changed = screen != _prev_compact_screen

    # Diff interactive elements
    prev_fp = _prev_compact_fingerprints if not screen_changed else {}
    prev_text = _prev_compact_text if not screen_changed else set()
    prev_ocr = _prev_compact_ocr if not screen_changed else set()

    added_keys = set(cur_fingerprints) - set(prev_fp)
    removed_keys = set(prev_fp) - set(cur_fingerprints)
    changed_keys = {k for k in set(cur_fingerprints) & set(prev_fp) if cur_fingerprints[k] != prev_fp[k]}
    unchanged_count = len(cur_fingerprints) - len(added_keys) - len(changed_keys)

    new_text = cur_text - prev_text
    removed_text = prev_text - cur_text
    unchanged_text_count = len(cur_text) - len(new_text)

    new_ocr = cur_ocr - prev_ocr
    removed_ocr = prev_ocr - cur_ocr
    unchanged_ocr_count = len(cur_ocr) - len(new_ocr)

    # Update stored state
    _prev_compact_fingerprints = cur_fingerprints
    _prev_compact_screen = screen
    _prev_compact_text = cur_text
    _prev_compact_ocr = cur_ocr

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
            lines.append(f"  !! SYSTEM DIALOG: {title} [{btn_str}]")
            for btn in buttons:
                lines.append(f'       → dialog dismiss button="{btn}"')
        lines.append("       → dialog dismiss_system (auto-detect and dismiss)")

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
            lines.append(dim(f"--- {len(show_keys)} changed, {unchanged_count} unchanged ---"))
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

    # Non-interactive text (grouped under containing interactive elements)
    if screen_changed or not prev_text:
        if ni:
            lines.append("")
            lines.append(dim("--- text ---"))
            ordered, grouped, ungrouped = _group_text_by_container(
                all_interactive, ni, data.get("screen_size"))
            lines.extend(_render_grouped_text(ordered, grouped, ungrouped, dim))
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

    # OCR-only text
    if ocr_results:
        if screen_changed or not prev_ocr:
            lines.append("")
            lines.append(dim("── ocr-only text ──"))
            for item in ocr_results:
                lines.append(_format_ocr_line(item))
        else:
            ocr_changes = new_ocr | removed_ocr
            if ocr_changes:
                lines.append("")
                lines.append(
                    dim(f"── ocr: {len(new_ocr)} new, {len(removed_ocr)} gone, {unchanged_ocr_count} unchanged ──")
                )
                for t in sorted(new_ocr):
                    lines.append(f"  + [ocr] {dim(t)}")
                for t in sorted(removed_ocr):
                    lines.append(f"  - [ocr] {dim(t)}")

    # Leaks (only significant — minor jitter filtered at dylib level)
    leaks = data.get("leaks", [])
    if leaks:
        lines.append("")
        lines.append("--- leaks ---")
        for leak in leaks[:5]:
            cls = leak.get("class", "?")
            delta = leak.get("delta", 0)
            suffix = " (sustained)" if leak.get("sustained") else ""
            lines.append(f"  {cls} (+{delta}){suffix}")

    # Scroll indicators — surface hidden off-screen content
    lines.extend(_scroll_indicator_lines(
        data, total_interactive, len(all_interactive), total_ni, len(ni)))

    return "\n".join(lines)

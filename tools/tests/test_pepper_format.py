"""Unit tests for pepper_format.py — ANSI helpers and look output formatters."""
from __future__ import annotations

import pepper_format as pf

# ---------------------------------------------------------------------------
# ANSI color helpers
# ---------------------------------------------------------------------------

class TestColorHelpers:
    def setup_method(self):
        pf.USE_COLOR = False

    def test_color_off_returns_plain_text(self):
        assert pf.green("hello") == "hello"
        assert pf.red("x") == "x"

    def test_color_on_wraps_ansi(self):
        pf.USE_COLOR = True
        result = pf.green("ok")
        assert result.startswith("\033[")
        assert "ok" in result
        assert result.endswith("\033[0m")

    def test_bold_off(self):
        assert pf.bold("B") == "B"

    def test_dim_off(self):
        assert pf.dim("D") == "D"


# ---------------------------------------------------------------------------
# Shared test data helpers
# ---------------------------------------------------------------------------

def _make_response(screen="TestVC", rows=None, ni=None, screen_size=None, **kwargs):
    data = {
        "screen": screen,
        "rows": rows or [],
        "non_interactive": ni or [],
    }
    if screen_size:
        data["screen_size"] = screen_size
    data.update(kwargs)
    return {"status": "ok", "data": data}


def _make_element(label="Tap me", etype="button", center=(100, 200),
                  tap_cmd="text", **kwargs):
    e = {
        "label": label,
        "type": etype,
        "center": list(center),
        "tap_cmd": tap_cmd,
    }
    e.update(kwargs)
    return e


# ---------------------------------------------------------------------------
# format_look
# ---------------------------------------------------------------------------

class TestFormatLook:
    def setup_method(self):
        pf.USE_COLOR = False

    def test_error_status_returns_json(self):
        resp = {"status": "error", "message": "boom"}
        result = pf.format_look(resp)
        assert '"status"' in result
        assert '"error"' in result

    def test_basic_response_contains_screen(self):
        result = pf.format_look(_make_response(screen="HomeVC"))
        assert "HomeVC" in result

    def test_interactive_count_in_header(self):
        e = _make_element()
        row = {"y_range": [180, 220], "elements": [e]}
        result = pf.format_look(_make_response(rows=[row]))
        assert "1 interactive" in result

    def test_non_interactive_count_in_header(self):
        ni = [{"label": "Hello"}]
        result = pf.format_look(_make_response(ni=ni))
        assert "1 text" in result

    def test_tap_text_in_output(self):
        e = _make_element(label="Save", tap_cmd="text")
        row = {"y_range": [180, 220], "elements": [e]}
        result = pf.format_look(_make_response(rows=[row]))
        assert 'tap text:"Save"' in result

    def test_tap_point_fallback(self):
        e = _make_element(label="", tap_cmd="point", center=(55, 77))
        row = {"y_range": [50, 100], "elements": [e]}
        result = pf.format_look(_make_response(rows=[row]))
        assert "tap point:55,77" in result

    def test_viewport_filter_removes_offscreen(self):
        # Element at center (500, 500) outside 100x100 viewport
        e = _make_element(label="Hidden", center=(500, 500))
        row = {"y_range": [490, 510], "elements": [e]}
        result = pf.format_look(_make_response(
            rows=[row],
            screen_size={"w": 100, "h": 100},
        ))
        assert "Hidden" not in result

    def test_viewport_keeps_onscreen_element(self):
        e = _make_element(label="Visible", center=(50, 50))
        row = {"y_range": [30, 70], "elements": [e]}
        result = pf.format_look(_make_response(
            rows=[row],
            screen_size={"w": 100, "h": 100},
        ))
        assert "Visible" in result

    def test_nav_title_in_header(self):
        result = pf.format_look(_make_response(nav_title="Settings"))
        assert "Settings" in result

    def test_memory_mb_in_header(self):
        resp = _make_response()
        resp["data"]["memory_mb"] = 42.7
        result = pf.format_look(resp)
        assert "43MB" in result or "42MB" in result

    def test_leak_warning_shown(self):
        resp = _make_response()
        resp["data"]["leaks"] = [{"class": "UIView", "before": 1, "after": 3, "delta": 2}]
        result = pf.format_look(resp)
        assert "leaks" in result
        assert "UIView" in result

    def test_disabled_element_flag(self):
        e = _make_element(label="Go", traits=["notEnabled"])
        row = {"y_range": [0, 50], "elements": [e]}
        result = pf.format_look(_make_response(rows=[row]))
        assert "disabled" in result

    def test_selected_element_flag(self):
        e = _make_element(label="Option A", traits=["selected"])
        row = {"y_range": [0, 50], "elements": [e]}
        result = pf.format_look(_make_response(rows=[row]))
        assert "selected" in result


# ---------------------------------------------------------------------------
# format_look_slim
# ---------------------------------------------------------------------------

class TestFormatLookSlim:
    def setup_method(self):
        pf.USE_COLOR = False

    def test_error_status_returns_json(self):
        resp = {"status": "error"}
        result = pf.format_look_slim(resp)
        assert '"status"' in result

    def test_basic_flat_element_list(self):
        e = _make_element(label="Next", tap_cmd="text")
        row = {"y_range": [0, 50], "elements": [e]}
        result = pf.format_look_slim(_make_response(rows=[row]))
        assert "Next" in result

    def test_no_y_range_headers(self):
        e = _make_element(label="A", tap_cmd="text")
        row = {"y_range": [10, 50], "elements": [e]}
        result = pf.format_look_slim(_make_response(rows=[row]))
        # format_look_slim shows no y= group headers
        assert "y=" not in result

    def test_system_dialog_warning(self):
        resp = _make_response()
        resp["data"]["system_dialog_blocking"] = {
            "dialogs": [{"title": "Location Access", "buttons": ["Allow", "Deny"]}]
        }
        result = pf.format_look_slim(resp)
        assert "DIALOG" in result
        assert "Location Access" in result


# ---------------------------------------------------------------------------
# format_look_compact (diff mode)
# ---------------------------------------------------------------------------

class TestFormatLookCompact:
    def setup_method(self):
        pf.USE_COLOR = False
        # Reset module-level diff state
        pf._prev_compact_fingerprints = {}
        pf._prev_compact_screen = ""
        pf._prev_compact_text = set()

    def test_first_call_shows_all_elements(self):
        e = _make_element(label="Submit", tap_cmd="text")
        row = {"y_range": [0, 50], "elements": [e]}
        result = pf.format_look_compact(_make_response(rows=[row]))
        assert "Submit" in result

    def test_second_call_same_state_shows_no_changes(self):
        e = _make_element(label="Submit", tap_cmd="text")
        row = {"y_range": [0, 50], "elements": [e]}
        resp = _make_response(rows=[row])
        pf.format_look_compact(resp)  # first call
        result = pf.format_look_compact(resp)  # second call — no changes
        assert "no interactive changes" in result

    def test_new_element_marked_added(self):
        e1 = _make_element(label="A", tap_cmd="text")
        row1 = {"y_range": [0, 50], "elements": [e1]}
        pf.format_look_compact(_make_response(rows=[row1]))

        e2 = _make_element(label="B", tap_cmd="text")
        row2 = {"y_range": [0, 100], "elements": [e1, e2]}
        result = pf.format_look_compact(_make_response(rows=[row2]))
        assert "B" in result
        # New element should show with "+" prefix
        assert "+" in result

    def test_screen_change_resets_diff(self):
        e = _make_element(label="X", tap_cmd="text")
        row = {"y_range": [0, 50], "elements": [e]}
        pf.format_look_compact(_make_response(screen="ScreenA", rows=[row]))
        result = pf.format_look_compact(_make_response(screen="ScreenB", rows=[row]))
        # After screen change, full list shown (no diff summary line)
        assert "no interactive changes" not in result
        assert "X" in result

    def test_error_status_returns_json(self):
        result = pf.format_look_compact({"status": "error"})
        assert '"status"' in result

    def test_removed_element_shown(self):
        e1 = _make_element(label="Old", tap_cmd="text")
        row = {"y_range": [0, 50], "elements": [e1]}
        pf.format_look_compact(_make_response(rows=[row]))

        # Second call with no elements
        result = pf.format_look_compact(_make_response(rows=[]))
        assert "removed" in result or "Old" in result

    def test_toggle_state_change_shown(self):
        e_off = _make_element(label="Switch", etype="switch", tap_cmd="text",
                              toggle_state="off")
        row = {"y_range": [0, 50], "elements": [e_off]}
        pf.format_look_compact(_make_response(rows=[row]))

        e_on = _make_element(label="Switch", etype="switch", tap_cmd="text",
                             toggle_state="on")
        row2 = {"y_range": [0, 50], "elements": [e_on]}
        result = pf.format_look_compact(_make_response(rows=[row2]))
        assert "on" in result or "~" in result


# ---------------------------------------------------------------------------
# _element_key / _element_state (internal helpers)
# ---------------------------------------------------------------------------

class TestElementHelpers:
    def test_element_key_stable(self):
        e = _make_element(label="Foo", etype="button", index=2)
        k1 = pf._element_key(e)
        k2 = pf._element_key(e)
        assert k1 == k2

    def test_element_key_distinguishes_label(self):
        e1 = _make_element(label="A")
        e2 = _make_element(label="B")
        assert pf._element_key(e1) != pf._element_key(e2)

    def test_element_state_empty(self):
        e = _make_element()
        assert pf._element_state(e) == ""

    def test_element_state_selected(self):
        e = _make_element()
        e["selected"] = True
        assert "sel" in pf._element_state(e)

    def test_element_state_toggle_on(self):
        e = _make_element()
        e["toggle_state"] = "on"
        assert "tog:on" in pf._element_state(e)

    def test_element_state_disabled(self):
        e = _make_element(traits=["notEnabled"])
        assert "disabled" in pf._element_state(e)

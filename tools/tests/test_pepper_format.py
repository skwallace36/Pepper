"""Unit tests for pepper_format.py — ANSI helpers and look output formatters."""

from __future__ import annotations

import pepper_ios.pepper_format as pf

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


def _make_element(label="Tap me", etype="button", center=(100, 200), tap_cmd="text", **kwargs):
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
        result = pf.format_look(
            _make_response(
                rows=[row],
                screen_size={"w": 100, "h": 100},
            )
        )
        assert "Hidden" not in result

    def test_viewport_keeps_onscreen_element(self):
        e = _make_element(label="Visible", center=(50, 50))
        row = {"y_range": [30, 70], "elements": [e]}
        result = pf.format_look(
            _make_response(
                rows=[row],
                screen_size={"w": 100, "h": 100},
            )
        )
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
        e_off = _make_element(label="Switch", etype="switch", tap_cmd="text", toggle_state="off")
        row = {"y_range": [0, 50], "elements": [e_off]}
        pf.format_look_compact(_make_response(rows=[row]))

        e_on = _make_element(label="Switch", etype="switch", tap_cmd="text", toggle_state="on")
        row2 = {"y_range": [0, 50], "elements": [e_on]}
        result = pf.format_look_compact(_make_response(rows=[row2]))
        assert "on" in result or "~" in result

    def test_compact_includes_tap_command(self):
        e = _make_element(label="Submit", tap_cmd="text")
        row = {"y_range": [0, 50], "elements": [e]}
        result = pf.format_look_compact(_make_response(rows=[row]))
        assert 'tap text:"Submit"' in result

    def test_hex_address_in_screen_name_does_not_break_diff(self):
        """Screen names with memory addresses should be normalized so the
        diff engages on the second call even when the address differs."""
        e = _make_element(label="OK", tap_cmd="text")
        row = {"y_range": [0, 50], "elements": [e]}
        pf.format_look_compact(_make_response(screen="<UINavController: 0xaaa>", rows=[row]))
        result = pf.format_look_compact(_make_response(screen="<UINavController: 0xbbb>", rows=[row]))
        assert "no interactive changes" in result

    def test_compact_uses_short_flags(self):
        e = _make_element(label="X", tap_cmd="text", selected=True, traits=["selected"])
        row = {"y_range": [0, 50], "elements": [e]}
        result = pf.format_look_compact(_make_response(rows=[row]))
        assert "[sel]" in result


# ---------------------------------------------------------------------------
# _normalize_screen
# ---------------------------------------------------------------------------


class TestNormalizeScreen:
    def test_strips_hex_address(self):
        assert pf._normalize_screen("<UINavController: 0x7fb5a2d>") == "UINavController"

    def test_extracts_private_view_name(self):
        assert pf._normalize_screen("_custom_view stuff") == "_custom_view"

    def test_truncates_long_names(self):
        long_name = "A" * 80
        result = pf._normalize_screen(long_name)
        assert len(result) <= 60

    def test_passes_through_short_names(self):
        assert pf._normalize_screen("HomeVC") == "HomeVC"


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


# ---------------------------------------------------------------------------
# OCR formatting
# ---------------------------------------------------------------------------


def _make_ocr_item(text="Hello World", center=(150, 300), confidence=0.92):
    return {"text": text, "center": list(center), "confidence": confidence}


class TestFormatLookOCR:
    def setup_method(self):
        pf.USE_COLOR = False

    def test_ocr_section_shown(self):
        resp = _make_response(ocr_results=[_make_ocr_item()])
        result = pf.format_look(resp)
        assert "ocr-only text" in result
        assert "Hello World" in result

    def test_ocr_format_includes_point_and_conf(self):
        resp = _make_response(ocr_results=[_make_ocr_item(center=(150, 300), confidence=0.95)])
        result = pf.format_look(resp)
        assert "point:150,300" in result
        assert "conf:0.95" in result

    def test_no_ocr_section_when_empty(self):
        resp = _make_response()
        result = pf.format_look(resp)
        assert "ocr-only text" not in result

    def test_ocr_long_text_truncated(self):
        long_text = "A" * 60
        resp = _make_response(ocr_results=[_make_ocr_item(text=long_text)])
        result = pf.format_look(resp)
        assert "..." in result
        assert long_text not in result


class TestFormatLookSlimOCR:
    def setup_method(self):
        pf.USE_COLOR = False

    def test_ocr_tagged_in_slim(self):
        resp = _make_response(ocr_results=[_make_ocr_item(text="Pixel Text")])
        result = pf.format_look_slim(resp)
        assert "[ocr]" in result
        assert "Pixel Text" in result

    def test_ocr_point_and_conf_in_slim(self):
        resp = _make_response(ocr_results=[_make_ocr_item(center=(42, 99), confidence=0.88)])
        result = pf.format_look_slim(resp)
        assert "point:42,99" in result
        assert "conf:0.88" in result


class TestFormatLookCompactOCR:
    def setup_method(self):
        pf.USE_COLOR = False
        pf._prev_compact_fingerprints = {}
        pf._prev_compact_screen = ""
        pf._prev_compact_text = set()
        pf._prev_compact_ocr = set()

    def test_first_call_shows_all_ocr(self):
        resp = _make_response(ocr_results=[_make_ocr_item(text="OCR Text")])
        result = pf.format_look_compact(resp)
        assert "ocr-only text" in result
        assert "OCR Text" in result

    def test_second_call_same_ocr_no_section(self):
        resp = _make_response(ocr_results=[_make_ocr_item(text="Stable")])
        pf.format_look_compact(resp)
        result = pf.format_look_compact(resp)
        # No OCR changes, no OCR section shown
        assert "ocr-only text" not in result
        assert "ocr:" not in result

    def test_new_ocr_text_shown_as_added(self):
        resp1 = _make_response(ocr_results=[_make_ocr_item(text="First")])
        pf.format_look_compact(resp1)
        resp2 = _make_response(
            ocr_results=[
                _make_ocr_item(text="First"),
                _make_ocr_item(text="Second"),
            ]
        )
        result = pf.format_look_compact(resp2)
        assert "1 new" in result
        assert "Second" in result

    def test_removed_ocr_text_shown(self):
        resp1 = _make_response(ocr_results=[_make_ocr_item(text="Gone")])
        pf.format_look_compact(resp1)
        resp2 = _make_response(ocr_results=[])
        pf.format_look_compact(resp2)
        assert pf._prev_compact_ocr == set()

    def test_screen_change_resets_ocr_diff(self):
        resp1 = _make_response(screen="ScreenA", ocr_results=[_make_ocr_item(text="Old")])
        pf.format_look_compact(resp1)
        resp2 = _make_response(screen="ScreenB", ocr_results=[_make_ocr_item(text="New")])
        result = pf.format_look_compact(resp2)
        # Screen changed → full OCR list shown, not diff
        assert "ocr-only text" in result
        assert "New" in result


# ---------------------------------------------------------------------------
# Text grouping under parent containers
# ---------------------------------------------------------------------------


class TestGroupTextByContainer:
    def test_groups_text_under_containing_element(self):
        interactive = [
            {"label": "Steps", "frame": [10, 100, 180, 200]},
        ]
        ni = [
            {"label": "1,932", "center": [100, 150]},
            {"label": "16% of goal", "center": [100, 180]},
        ]
        ordered, grouped, ungrouped = pf._group_text_by_container(interactive, ni)
        assert ordered == ["Steps"]
        assert grouped["Steps"] == ["1,932", "16% of goal"]
        assert ungrouped == []

    def test_ungrouped_text_when_outside_containers(self):
        interactive = [{"label": "Card", "frame": [10, 10, 100, 100]}]
        ni = [{"label": "outside", "center": [300, 300]}]
        ordered, grouped, ungrouped = pf._group_text_by_container(interactive, ni)
        assert ordered == []
        assert ungrouped == ["outside"]

    def test_skips_text_matching_container_label(self):
        interactive = [{"label": "Steps", "frame": [10, 100, 180, 200]}]
        ni = [
            {"label": "Steps", "center": [100, 150]},
            {"label": "1,932", "center": [100, 180]},
        ]
        ordered, grouped, ungrouped = pf._group_text_by_container(interactive, ni)
        assert grouped["Steps"] == ["1,932"]
        assert "Steps" in ungrouped

    def test_smallest_container_wins(self):
        interactive = [
            {"label": "Outer", "frame": [0, 0, 300, 300]},
            {"label": "Inner", "frame": [10, 10, 100, 100]},
        ]
        ni = [{"label": "deep", "center": [50, 50]}]
        ordered, grouped, ungrouped = pf._group_text_by_container(interactive, ni)
        assert ordered == ["Inner"]
        assert grouped["Inner"] == ["deep"]

    def test_skips_fullscreen_containers(self):
        interactive = [{"label": "Root", "frame": [0, 0, 400, 800]}]
        ni = [{"label": "text", "center": [200, 400]}]
        ordered, grouped, ungrouped = pf._group_text_by_container(
            interactive, ni, screen_size={"w": 400, "h": 800})
        assert ordered == []
        assert ungrouped == ["text"]

    def test_empty_ni_returns_empty(self):
        ordered, grouped, ungrouped = pf._group_text_by_container([{"label": "X", "frame": [0, 0, 100, 100]}], [])
        assert ordered == []
        assert grouped == {}
        assert ungrouped == []

    def test_no_containers_returns_all_ungrouped(self):
        ni = [{"label": "hello", "center": [0, 0]}]
        ordered, grouped, ungrouped = pf._group_text_by_container([], ni)
        assert ungrouped == ["hello"]


class TestRenderGroupedText:
    def test_renders_groups_then_ungrouped(self):
        lines = pf._render_grouped_text(
            ["Card"], {"Card": ["val1", "val2"]}, ["loose"], lambda x: x)
        assert lines == ["  Card:", "    val1", "    val2", "  loose"]

    def test_empty_groups(self):
        lines = pf._render_grouped_text([], {}, ["a", "b"], lambda x: x)
        assert lines == ["  a", "  b"]


class TestFormatLookGroupedText:
    def setup_method(self):
        pf.USE_COLOR = False

    def test_format_look_groups_text(self):
        card = _make_element(label="Steps", frame=[10, 100, 180, 200])
        row = {"y_range": [100, 300], "elements": [card]}
        ni = [
            {"label": "1,932", "center": [100, 150]},
            {"label": "16%", "center": [100, 180]},
        ]
        result = pf.format_look(_make_response(rows=[row], ni=ni))
        assert "Steps:" in result
        assert "1,932" in result
        assert "16%" in result

    def test_format_look_slim_groups_text(self):
        card = _make_element(label="Steps", frame=[10, 100, 180, 200])
        row = {"y_range": [100, 300], "elements": [card]}
        ni = [
            {"label": "1,932", "center": [100, 150]},
        ]
        result = pf.format_look_slim(_make_response(rows=[row], ni=ni))
        assert "Steps:" in result
        assert "1,932" in result

    def test_format_look_compact_groups_text(self):
        pf._prev_compact_fingerprints = {}
        pf._prev_compact_screen = None
        pf._prev_compact_text = set()
        pf._prev_compact_ocr = set()
        card = _make_element(label="Steps", frame=[10, 100, 180, 200])
        row = {"y_range": [100, 300], "elements": [card]}
        ni = [
            {"label": "1,932", "center": [100, 150]},
        ]
        result = pf.format_look_compact(_make_response(rows=[row], ni=ni))
        assert "Steps:" in result
        assert "1,932" in result

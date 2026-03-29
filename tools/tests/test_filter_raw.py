"""Unit tests for filter_raw in mcp_tools_nav.py."""

from __future__ import annotations

from pepper_ios.pepper_format import filter_raw


def _make_resp():
    """Build a minimal raw look response for testing."""
    return {
        "status": "ok",
        "id": "test-1",
        "data": {
            "element_count": 4,
            "rows": [
                {
                    "y_range": [80, 120],
                    "elements": [
                        {
                            "type": "button", "label": "Settings",
                            "tap_cmd": "text", "center": [195, 100],
                            "frame": [150, 80, 90, 40],
                        },
                        {
                            "type": "textField", "label": "Search",
                            "tap_cmd": "text", "center": [195, 100],
                            "frame": [10, 80, 370, 40],
                        },
                    ],
                },
                {
                    "y_range": [200, 240],
                    "elements": [
                        {
                            "type": "button", "label": "Save",
                            "tap_cmd": "text", "center": [195, 220],
                            "frame": [150, 200, 90, 40],
                        },
                    ],
                },
            ],
            "non_interactive": [
                {
                    "type": "staticText", "label": "Welcome",
                    "center": [195, 50], "frame": [50, 30, 290, 40],
                },
            ],
        },
    }


class TestFilterByType:
    def test_filter_buttons_only(self):
        result = filter_raw(_make_resp(), "button", None)
        data = result["data"]
        all_els = [e for r in data["rows"] for e in r["elements"]]
        assert len(all_els) == 2
        assert all(e["type"] == "button" for e in all_els)
        assert data["non_interactive"] == []
        assert data["element_count"] == 2

    def test_filter_case_insensitive(self):
        result = filter_raw(_make_resp(), "BUTTON", None)
        all_els = [e for r in result["data"]["rows"] for e in r["elements"]]
        assert len(all_els) == 2

    def test_filter_substring_match(self):
        result = filter_raw(_make_resp(), "text", None)
        data = result["data"]
        interactive = [e for r in data["rows"] for e in r["elements"]]
        assert len(interactive) == 1
        assert interactive[0]["type"] == "textField"
        assert len(data["non_interactive"]) == 1
        assert data["non_interactive"][0]["type"] == "staticText"

    def test_filter_removes_empty_rows(self):
        result = filter_raw(_make_resp(), "textField", None)
        data = result["data"]
        assert len(data["rows"]) == 1

    def test_filter_no_match(self):
        result = filter_raw(_make_resp(), "slider", None)
        data = result["data"]
        assert data["rows"] == []
        assert data["non_interactive"] == []
        assert data["element_count"] == 0


class TestFieldsProjection:
    def test_fields_projects_keys(self):
        result = filter_raw(_make_resp(), None, "label,type")
        data = result["data"]
        for row in data["rows"]:
            for el in row["elements"]:
                assert set(el.keys()) == {"label", "type"}

    def test_fields_projects_non_interactive(self):
        result = filter_raw(_make_resp(), None, "label,frame")
        ni = result["data"]["non_interactive"]
        assert len(ni) == 1
        assert set(ni[0].keys()) == {"label", "frame"}

    def test_fields_missing_key_skipped(self):
        result = filter_raw(_make_resp(), None, "label,nonexistent")
        el = result["data"]["rows"][0]["elements"][0]
        assert "label" in el
        assert "nonexistent" not in el


class TestFilterAndFields:
    def test_combined(self):
        result = filter_raw(_make_resp(), "button", "label,frame")
        data = result["data"]
        all_els = [e for r in data["rows"] for e in r["elements"]]
        assert len(all_els) == 2
        for el in all_els:
            assert set(el.keys()) == {"label", "frame"}
        assert data["non_interactive"] == []
        assert data["element_count"] == 2


class TestNoop:
    def test_no_filter_no_fields_passthrough(self):
        original = _make_resp()
        result = filter_raw(_make_resp(), None, None)
        assert result["data"]["element_count"] == original["data"]["element_count"]
        assert len(result["data"]["rows"]) == len(original["data"]["rows"])

    def test_does_not_mutate_input(self):
        original = _make_resp()
        orig_count = original["data"]["element_count"]
        filter_raw(original, "button", None)
        assert original["data"]["element_count"] == orig_count

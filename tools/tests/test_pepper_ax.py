"""Tests for the structural decision in pepper_ax dialog detection.

Skips on non-macOS — pepper_ax fails to import without CoreFoundation /
ApplicationServices.
"""

from __future__ import annotations

import sys

import pytest

if sys.platform != "darwin":
    pytest.skip("pepper_ax requires macOS", allow_module_level=True)

from pepper_ios.pepper_ax import _select_dialog_buttons  # noqa: E402

# Each iOS screen rect: (x, y, w, h). One canonical 393x852 portrait phone.
SCREEN = [(0.0, 0.0, 393.0, 852.0)]


def _btn(title: str, x: float, y: float, w: float, h: float, sentinel: object):
    """Build a synthetic button tuple. The last slot is normally a CFRetained
    AXUIElementRef; tests pass a unique object so id()-based set membership
    in `_select_dialog_buttons` still works."""
    return (title, x, y, w, h, sentinel)


def test_app_screen_cluster_is_not_a_dialog():
    """A list of equally-sized rows on a normal screen (toggle list,
    segmented control, tab bar) must not be classified as a dialog. This is
    the regression that produced the bogus
    `[Sound, Vibration, Fitness, Preview]` "system dialog" warning."""
    inside = [
        _btn("Sound", 16.0, 200.0, 361.0, 44.0, object()),
        _btn("Vibration", 16.0, 245.0, 361.0, 44.0, object()),
        _btn("Fitness", 16.0, 290.0, 361.0, 44.0, object()),
        _btn("Preview", 16.0, 335.0, 361.0, 44.0, object()),
    ]
    kept, dropped = _select_dialog_buttons(inside, [], SCREEN, sheet_present=False)
    assert kept == []
    assert len(dropped) == 4


def test_sibling_subtree_cluster_is_a_dialog():
    """The same shape of cluster, but in the sibling subtree (where
    SpringBoard renders permission dialogs), must be classified as a
    dialog."""
    outside = [
        _btn("Limit Access…", 16.0, 600.0, 361.0, 44.0, object()),
        _btn("Allow Full Access", 16.0, 645.0, 361.0, 44.0, object()),
        _btn("Keep Add Only", 16.0, 690.0, 361.0, 44.0, object()),
    ]
    kept, _dropped = _select_dialog_buttons([], outside, SCREEN, sheet_present=False)
    titles = [t[0] for t in kept]
    assert titles == ["Limit Access…", "Allow Full Access", "Keep Add Only"]


def test_sheet_present_returns_all_on_screen_buttons():
    """When AXSheet/AXDialog role is present, the role itself is the signal
    — both subtrees count, no cluster needed."""
    inside = [_btn("App Button", 16.0, 100.0, 100.0, 44.0, object())]
    outside = [_btn("OK", 150.0, 600.0, 80.0, 44.0, object())]
    kept, dropped = _select_dialog_buttons(inside, outside, SCREEN, sheet_present=True)
    assert {t[0] for t in kept} == {"App Button", "OK"}
    assert dropped == []


def test_off_screen_buttons_are_dropped():
    """Buttons whose center sits outside every iOSContentGroup rect — the
    Simulator's hardware bezel buttons (Action, Volume, Home) — must be
    excluded from the kept list."""
    bezel = [
        _btn("Action", -50.0, 200.0, 30.0, 60.0, object()),
        _btn("Volume Up", -50.0, 280.0, 30.0, 60.0, object()),
    ]
    kept, dropped = _select_dialog_buttons([], bezel, SCREEN, sheet_present=False)
    assert kept == []
    assert len(dropped) == 2


def test_single_outside_button_is_not_a_dialog():
    """One button alone in the sibling subtree doesn't form a cluster — no
    dialog. Guards against treating, e.g., a stray AppKit button as a
    permission prompt."""
    outside = [_btn("Lone", 16.0, 400.0, 361.0, 44.0, object())]
    kept, dropped = _select_dialog_buttons([], outside, SCREEN, sheet_present=False)
    assert kept == []
    assert len(dropped) == 1

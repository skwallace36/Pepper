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


def _btn(title: str, x: float, y: float, w: float, h: float, sentinel: object, depth: int = 3):
    """Build a synthetic button tuple. The element slot is normally a
    CFRetained AXUIElementRef; tests pass a unique object so id()-based set
    membership in `_select_dialog_buttons` still works.

    `depth` is screen_depth from the iOSContentGroup ancestor (1 = direct
    child, deeper = nested under scroll views/lists/etc). Defaults to 3 to
    model typical app UI; tests targeting the dialog fallback pass depth=1
    explicitly. -1 means the button isn't under any iOSContentGroup
    (sibling subtree).
    """
    return (title, x, y, w, h, sentinel, depth)


def test_app_screen_cluster_is_not_a_dialog():
    """A list of equally-sized rows on a normal screen (toggle list,
    segmented control, tab bar) must not be classified as a dialog. Such
    rows are nested deep in the AX tree (scroll view → list → row → button),
    so they sit at depth ≥ 2 from iOSContentGroup. The dialog fallback only
    accepts direct children (depth==1) to avoid this misfire."""
    inside = [
        _btn("Sound", 16.0, 200.0, 361.0, 44.0, object(), depth=4),
        _btn("Vibration", 16.0, 245.0, 361.0, 44.0, object(), depth=4),
        _btn("Fitness", 16.0, 290.0, 361.0, 44.0, object(), depth=4),
        _btn("Preview", 16.0, 335.0, 361.0, 44.0, object(), depth=4),
    ]
    kept, dropped = _select_dialog_buttons(inside, [], SCREEN, sheet_present=False)
    assert kept == []
    assert len(dropped) == 4


def test_sibling_subtree_cluster_is_a_dialog():
    """The same shape of cluster, but in the sibling subtree (where
    SpringBoard renders some permission dialogs), must be classified as a
    dialog."""
    outside = [
        _btn("Limit Access…", 16.0, 600.0, 361.0, 44.0, object(), depth=-1),
        _btn("Allow Full Access", 16.0, 645.0, 361.0, 44.0, object(), depth=-1),
        _btn("Keep Add Only", 16.0, 690.0, 361.0, 44.0, object(), depth=-1),
    ]
    kept, _dropped = _select_dialog_buttons([], outside, SCREEN, sheet_present=False)
    titles = [t[0] for t in kept]
    assert titles == ["Limit Access…", "Allow Full Access", "Keep Add Only"]


def test_inside_iosgroup_cluster_at_depth_1_is_a_dialog():
    """iOS 26.3 SpringBoard renders the photo permission alert as direct
    children of iOSContentGroup, replacing the app's AX subtree. Buttons
    land in `inside` at depth==1, no AXSheet/AXDialog role exposed.
    The depth==1 fallback must catch them."""
    inside = [
        _btn("Limit Access…", 57.0, 567.0, 288.0, 48.0, object(), depth=1),
        _btn("Allow Full Access", 57.0, 623.0, 288.0, 48.0, object(), depth=1),
        _btn("Don’t Allow", 57.0, 679.0, 288.0, 48.0, object(), depth=1),
    ]
    kept, _dropped = _select_dialog_buttons(inside, [], SCREEN, sheet_present=False)
    titles = [t[0] for t in kept]
    assert titles == ["Limit Access…", "Allow Full Access", "Don’t Allow"]


def test_inside_cluster_rejects_narrow_buttons():
    """Two narrow stat-style buttons at depth==1 (e.g. profile screen
    "Followers, 28 / Following, 31" sitting side-by-side) form a horizontal
    cluster but aren't a dialog. The width gate (≥50% of screen width) must
    reject them."""
    inside = [
        _btn("Followers, 28", 16.0, 356.0, 62.0, 39.0, object(), depth=1),
        _btn("Following, 31", 106.0, 356.0, 62.0, 39.0, object(), depth=1),
    ]
    kept, dropped = _select_dialog_buttons(inside, [], SCREEN, sheet_present=False)
    assert kept == []
    assert len(dropped) == 2


def test_inside_cluster_only_accepts_direct_children():
    """A cluster whose buttons are nested deeper than depth==1 (anything
    inside a scroll view, list, or grouped container) must NOT be picked
    up by the inside fallback — that's the regression PR #1220 fixed."""
    inside = [
        _btn("Row A", 16.0, 200.0, 361.0, 44.0, object(), depth=2),
        _btn("Row B", 16.0, 245.0, 361.0, 44.0, object(), depth=2),
        _btn("Row C", 16.0, 290.0, 361.0, 44.0, object(), depth=2),
    ]
    kept, dropped = _select_dialog_buttons(inside, [], SCREEN, sheet_present=False)
    assert kept == []
    assert len(dropped) == 3


def test_sheet_present_returns_all_on_screen_buttons():
    """When AXSheet/AXDialog role is present, the role itself is the signal
    — both subtrees count, no cluster needed."""
    inside = [_btn("App Button", 16.0, 100.0, 100.0, 44.0, object())]
    outside = [_btn("OK", 150.0, 600.0, 80.0, 44.0, object(), depth=-1)]
    kept, dropped = _select_dialog_buttons(inside, outside, SCREEN, sheet_present=True)
    assert {t[0] for t in kept} == {"App Button", "OK"}
    assert dropped == []


def test_off_screen_buttons_are_dropped():
    """Buttons whose center sits outside every iOSContentGroup rect — the
    Simulator's hardware bezel buttons (Action, Volume, Home) — must be
    excluded from the kept list."""
    bezel = [
        _btn("Action", -50.0, 200.0, 30.0, 60.0, object(), depth=-1),
        _btn("Volume Up", -50.0, 280.0, 30.0, 60.0, object(), depth=-1),
    ]
    kept, dropped = _select_dialog_buttons([], bezel, SCREEN, sheet_present=False)
    assert kept == []
    assert len(dropped) == 2


def test_single_outside_button_is_not_a_dialog():
    """One button alone in the sibling subtree doesn't form a cluster — no
    dialog. Guards against treating, e.g., a stray AppKit button as a
    permission prompt."""
    outside = [_btn("Lone", 16.0, 400.0, 361.0, 44.0, object(), depth=-1)]
    kept, dropped = _select_dialog_buttons([], outside, SCREEN, sheet_present=False)
    assert kept == []
    assert len(dropped) == 1

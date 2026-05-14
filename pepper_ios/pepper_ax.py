"""pepper_ax -- macOS Accessibility API (AXUIElement) helper for Simulator dialog dismissal.

Uses ctypes to call macOS Accessibility APIs directly — no pyobjc dependency.
Finds the Simulator.app window, walks the accessibility tree to locate system
dialog buttons (permissions, deep link confirmations, etc.), and clicks them.
"""

from __future__ import annotations

import ctypes
import ctypes.util
import logging
import subprocess

logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Core Foundation + ApplicationServices via ctypes
# ---------------------------------------------------------------------------

_cf_path = ctypes.util.find_library("CoreFoundation")
_ax_path = ctypes.util.find_library("ApplicationServices")

if not _cf_path or not _ax_path:
    raise ImportError("CoreFoundation or ApplicationServices framework not found (macOS only)")

_cf = ctypes.cdll.LoadLibrary(_cf_path)
_ax = ctypes.cdll.LoadLibrary(_ax_path)

# Type aliases
CFTypeRef = ctypes.c_void_p
CFStringRef = ctypes.c_void_p
CFArrayRef = ctypes.c_void_p
CFIndex = ctypes.c_int64
CFBooleanRef = ctypes.c_void_p
AXUIElementRef = ctypes.c_void_p
AXError = ctypes.c_int32

kCFStringEncodingUTF8 = 0x08000100
kCFAllocatorDefault = None

# CoreFoundation functions
_cf.CFStringCreateWithCString.restype = CFStringRef
_cf.CFStringCreateWithCString.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_uint32]

_cf.CFStringGetCStringPtr.restype = ctypes.c_char_p
_cf.CFStringGetCStringPtr.argtypes = [CFStringRef, ctypes.c_uint32]

_cf.CFStringGetCString.restype = ctypes.c_bool
_cf.CFStringGetCString.argtypes = [CFStringRef, ctypes.c_char_p, CFIndex, ctypes.c_uint32]

_cf.CFStringGetLength.restype = CFIndex
_cf.CFStringGetLength.argtypes = [CFStringRef]

_cf.CFArrayGetCount.restype = CFIndex
_cf.CFArrayGetCount.argtypes = [CFArrayRef]

_cf.CFArrayGetValueAtIndex.restype = ctypes.c_void_p
_cf.CFArrayGetValueAtIndex.argtypes = [CFArrayRef, CFIndex]

_cf.CFRelease.restype = None
_cf.CFRelease.argtypes = [CFTypeRef]

_cf.CFRetain.restype = CFTypeRef
_cf.CFRetain.argtypes = [CFTypeRef]

_cf.CFGetTypeID.restype = ctypes.c_ulong
_cf.CFGetTypeID.argtypes = [CFTypeRef]

_cf.CFStringGetTypeID.restype = ctypes.c_ulong
_cf.CFArrayGetTypeID.restype = ctypes.c_ulong
_cf.CFBooleanGetTypeID.restype = ctypes.c_ulong

_cf.CFBooleanGetValue.restype = ctypes.c_bool
_cf.CFBooleanGetValue.argtypes = [CFBooleanRef]

# AXUIElement functions
_ax.AXUIElementCreateApplication.restype = AXUIElementRef
_ax.AXUIElementCreateApplication.argtypes = [ctypes.c_int32]

_ax.AXUIElementCopyAttributeValue.restype = AXError
_ax.AXUIElementCopyAttributeValue.argtypes = [AXUIElementRef, CFStringRef, ctypes.POINTER(CFTypeRef)]

_ax.AXUIElementCopyAttributeNames.restype = AXError
_ax.AXUIElementCopyAttributeNames.argtypes = [AXUIElementRef, ctypes.POINTER(CFArrayRef)]

_ax.AXUIElementPerformAction.restype = AXError
_ax.AXUIElementPerformAction.argtypes = [AXUIElementRef, CFStringRef]

# AXValue (boxed CGPoint/CGSize) accessor
_ax.AXValueGetValue.restype = ctypes.c_bool
_ax.AXValueGetValue.argtypes = [ctypes.c_void_p, ctypes.c_uint32, ctypes.c_void_p]

# AXError codes
kAXErrorSuccess = 0

# AXValue type tags
kAXValueCGPointType = 1
kAXValueCGSizeType = 2


class CGPoint(ctypes.Structure):
    _fields_ = [("x", ctypes.c_double), ("y", ctypes.c_double)]


class CGSize(ctypes.Structure):
    _fields_ = [("width", ctypes.c_double), ("height", ctypes.c_double)]


# ---------------------------------------------------------------------------
# CF helpers
# ---------------------------------------------------------------------------


def _cfstr(s: str) -> CFStringRef:
    """Create a CFString from a Python string. Caller must CFRelease."""
    return _cf.CFStringCreateWithCString(kCFAllocatorDefault, s.encode("utf-8"), kCFStringEncodingUTF8)


def _cfstr_to_py(ref: CFStringRef) -> str | None:
    """Convert a CFString to a Python string."""
    if not ref:
        return None
    ptr = _cf.CFStringGetCStringPtr(ref, kCFStringEncodingUTF8)
    if ptr:
        return ptr.decode("utf-8")
    # Fallback: allocate buffer
    length = _cf.CFStringGetLength(ref)
    buf_size = length * 4 + 1
    buf = ctypes.create_string_buffer(buf_size)
    if _cf.CFStringGetCString(ref, buf, buf_size, kCFStringEncodingUTF8):
        return buf.value.decode("utf-8")
    return None


def _get_attr(element: AXUIElementRef, attr_name: str) -> CFTypeRef | None:
    """Get an accessibility attribute value. Returns None on failure."""
    attr = _cfstr(attr_name)
    value = CFTypeRef()
    try:
        err = _ax.AXUIElementCopyAttributeValue(element, attr, ctypes.byref(value))
        if err != kAXErrorSuccess:
            return None
        return value
    finally:
        _cf.CFRelease(attr)


def _get_str_attr(element: AXUIElementRef, attr_name: str) -> str | None:
    """Get a string accessibility attribute."""
    val = _get_attr(element, attr_name)
    if val is None:
        return None
    try:
        type_id = _cf.CFGetTypeID(val)
        if type_id == _cf.CFStringGetTypeID():
            return _cfstr_to_py(val)
        return None
    finally:
        _cf.CFRelease(val)


def _get_children(element: AXUIElementRef) -> list[AXUIElementRef]:
    """Get child AXUIElements. Caller must CFRelease each child after use."""
    val = _get_attr(element, "AXChildren")
    if val is None:
        return []
    try:
        type_id = _cf.CFGetTypeID(val)
        if type_id != _cf.CFArrayGetTypeID():
            return []
        count = _cf.CFArrayGetCount(val)
        children = []
        for i in range(count):
            child = _cf.CFArrayGetValueAtIndex(val, i)
            if child:
                _cf.CFRetain(child)
                children.append(child)
        return children
    finally:
        _cf.CFRelease(val)


# ---------------------------------------------------------------------------
# Simulator PID discovery
# ---------------------------------------------------------------------------


def _find_simulator_pids() -> list[int]:
    """Find PIDs of running Simulator.app processes."""
    try:
        result = subprocess.run(
            ["pgrep", "-f", "Simulator.app/Contents/MacOS/Simulator"],
            capture_output=True,
            text=True,
            timeout=5,
        )
        if result.returncode != 0:
            return []
        return [int(pid.strip()) for pid in result.stdout.strip().split("\n") if pid.strip()]
    except (subprocess.TimeoutExpired, ValueError):
        return []


# ---------------------------------------------------------------------------
# Tree walking: find dialog buttons
# ---------------------------------------------------------------------------

# Buttons we prefer to tap, in priority order. Used by find_and_dismiss_dialog
# to choose a default action when no target_title is given. Not used for
# detection — detection is structural (role + frame clustering).
DEFAULT_BUTTON_TITLES = [
    "Allow While Using App",
    "Allow Once",
    "Allow",
    "Open",  # deep link / universal link confirmation
    "OK",
    "Continue",
    "Cancel",
    "Not Now",
    "Don\u2019t Allow",  # curly apostrophe
    "Don't Allow",  # straight apostrophe
]

# AXRole values for clickable elements
_BUTTON_ROLES = {"AXButton"}

# Frame-cluster tolerances. iOS alerts and action sheets stack equal-width
# buttons at a shared x-origin with a thin separator between them.
_CLUSTER_X_TOLERANCE = 5.0
_CLUSTER_W_TOLERANCE = 5.0
# Native separators are ~0.5pt; action-sheet "Cancel" buttons are detached
# by ~8pt; allow slack for scaling and theme variations.
_CLUSTER_MAX_GAP = 30.0
# Min cluster size. 2 covers the common Allow / Don't Allow alert.
_MIN_CLUSTER_SIZE = 2


def _find_ios_content_group(
    element: AXUIElementRef,
    depth: int = 0,
    max_depth: int = 8,
) -> AXUIElementRef | None:
    """Find the first AXGroup with subrole "iOSContentGroup". Returns a
    CFRetain'd ref the caller must CFRelease, or None. Used as a fallback
    when only one screen region is needed."""
    if depth > max_depth:
        return None
    subrole = _get_str_attr(element, "AXSubrole")
    if subrole == "iOSContentGroup":
        _cf.CFRetain(element)
        return element
    children = _get_children(element)
    found: AXUIElementRef | None = None
    for child in children:
        if found is None:
            found = _find_ios_content_group(child, depth + 1, max_depth)
        _cf.CFRelease(child)
    return found


def _find_ios_screen_rects(
    element: AXUIElementRef,
    out: list[tuple[float, float, float, float]],
    depth: int = 0,
    max_depth: int = 12,
):
    """Walk the tree collecting frames of every iOSContentGroup. Each booted
    simulator window contributes one rect; we use these as the "iOS screen"
    regions. Used to filter buttons by geometry — the AX tree may surface
    system-dialog buttons in a sibling window (not under iOSContentGroup),
    but they always render visually on top of an iOS screen region."""
    if depth > max_depth:
        return
    subrole = _get_str_attr(element, "AXSubrole")
    if subrole == "iOSContentGroup":
        frame = _get_frame(element)
        if frame is not None:
            out.append(frame)
        # Don't recurse into the content group — its frame already covers it.
        return
    children = _get_children(element)
    for child in children:
        _find_ios_screen_rects(child, out, depth + 1, max_depth)
        _cf.CFRelease(child)


def _frame_inside(
    inner: tuple[float, float, float, float],
    outer: tuple[float, float, float, float],
    tolerance: float = 1.0,
) -> bool:
    """True when the inner rect's center sits within `outer` (with slack).
    Center-test rather than full-containment because iOS dialogs sometimes
    render with a shadow that extends a few points past the screen edge."""
    ix, iy, iw, ih = inner
    ox, oy, ow, oh = outer
    cx = ix + iw / 2
    cy = iy + ih / 2
    return (ox - tolerance) <= cx <= (ox + ow + tolerance) and (
        oy - tolerance
    ) <= cy <= (oy + oh + tolerance)


def _button_title(element: AXUIElementRef) -> str | None:
    """Read a button's visible label. iOS sim dialogs expose labels via
    AXDescription; native AppKit buttons use AXTitle. Try both."""
    title = _get_str_attr(element, "AXTitle")
    if title:
        return title
    return _get_str_attr(element, "AXDescription")


def _find_buttons_recursive(
    element: AXUIElementRef,
    target_titles: set[str] | None,
    found: list[tuple[str, AXUIElementRef]],
    depth: int = 0,
    max_depth: int = 15,
):
    """Walk the accessibility tree and collect buttons.

    If target_titles is None, collects every AXButton encountered (used for
    dynamic dialog button enumeration — permission prompts can add new button
    titles each iOS release, and a hardcoded allowlist drops the ones we
    haven't heard of). If target_titles is a set, only buttons whose title
    is in the set are collected.
    """
    if depth > max_depth:
        return

    role = _get_str_attr(element, "AXRole")
    if role in _BUTTON_ROLES:
        title = _button_title(element)
        if title and (target_titles is None or title in target_titles):
            _cf.CFRetain(element)
            found.append((title, element))

    children = _get_children(element)
    for child in children:
        _find_buttons_recursive(child, target_titles, found, depth + 1, max_depth)
        _cf.CFRelease(child)


def _get_frame(element: AXUIElementRef) -> tuple[float, float, float, float] | None:
    """Read AXPosition + AXSize and return (x, y, w, h). None if either is missing."""
    pos_ref = _get_attr(element, "AXPosition")
    if pos_ref is None:
        return None
    size_ref = _get_attr(element, "AXSize")
    if size_ref is None:
        _cf.CFRelease(pos_ref)
        return None
    pt = CGPoint()
    sz = CGSize()
    ok_p = _ax.AXValueGetValue(pos_ref, kAXValueCGPointType, ctypes.byref(pt))
    ok_s = _ax.AXValueGetValue(size_ref, kAXValueCGSizeType, ctypes.byref(sz))
    _cf.CFRelease(pos_ref)
    _cf.CFRelease(size_ref)
    if not ok_p or not ok_s:
        return None
    return (pt.x, pt.y, sz.width, sz.height)


def _has_sheet_or_dialog_role(
    element: AXUIElementRef,
    depth: int = 0,
    max_depth: int = 10,
) -> bool:
    """Walk the tree looking for AXSheet/AXDialog roles. Free positive signal
    when iOS exposes it — most modern dialogs don't, hence the cluster fallback."""
    role = _get_str_attr(element, "AXRole")
    if role in ("AXSheet", "AXDialog"):
        return True
    if depth >= max_depth:
        return False
    children = _get_children(element)
    found = False
    for child in children:
        if not found:
            found = _has_sheet_or_dialog_role(child, depth + 1, max_depth)
        _cf.CFRelease(child)
    return found


def _collect_buttons_with_frames(
    element: AXUIElementRef,
    out: list[tuple[str, float, float, float, float, AXUIElementRef]],
    depth: int = 0,
    max_depth: int = 15,
):
    """Walk the tree collecting (title, x, y, w, h, retained_element) for every
    AXButton with a readable frame. Caller owns the retained refs."""
    if depth > max_depth:
        return
    role = _get_str_attr(element, "AXRole")
    if role in _BUTTON_ROLES:
        title = _button_title(element)
        frame = _get_frame(element)
        if title and frame is not None:
            x, y, w, h = frame
            _cf.CFRetain(element)
            out.append((title, x, y, w, h, element))
    children = _get_children(element)
    for child in children:
        _collect_buttons_with_frames(child, out, depth + 1, max_depth)
        _cf.CFRelease(child)


def _collect_buttons_classified(
    element: AXUIElementRef,
    in_screen: bool,
    inside: list[tuple[str, float, float, float, float, AXUIElementRef, int]],
    outside: list[tuple[str, float, float, float, float, AXUIElementRef, int]],
    depth: int = 0,
    max_depth: int = 20,
    screen_depth: int = -1,
):
    """Walk the window tree and split AXButtons into two buckets by ancestry:
    `inside` (descended from an iOSContentGroup) and `outside` (not). Caller
    owns the CFRetained refs in both lists.

    SpringBoard renders permission dialogs in two distinct shapes:
    - sibling subtree of iOSContentGroup → buttons land in `outside`
    - directly inside iOSContentGroup, replacing the app's AX subtree → buttons
      land in `inside` (observed on iOS 26.3 photo permission alerts)

    `screen_depth` records distance from the iOSContentGroup ancestor: 0 at
    iOSContentGroup itself, 1 for direct children, 2+ for deeper descendants.
    -1 means the button isn't under any iOSContentGroup. The depth lets the
    selection step distinguish dialog buttons (typically depth 1) from plain
    app UI like toggle rows (deep inside scroll views/lists).
    """
    if depth > max_depth:
        return
    subrole = _get_str_attr(element, "AXSubrole")
    if subrole == "iOSContentGroup":
        is_screen = True
        screen_depth = 0
    else:
        is_screen = in_screen
    role = _get_str_attr(element, "AXRole")
    if role in _BUTTON_ROLES:
        title = _button_title(element)
        frame = _get_frame(element)
        if title and frame is not None:
            x, y, w, h = frame
            _cf.CFRetain(element)
            tup = (title, x, y, w, h, element, screen_depth)
            if is_screen:
                inside.append(tup)
            else:
                outside.append(tup)
    children = _get_children(element)
    next_screen_depth = screen_depth + 1 if is_screen else -1
    for child in children:
        _collect_buttons_classified(
            child, is_screen, inside, outside, depth + 1, max_depth, next_screen_depth
        )
        _cf.CFRelease(child)


def _find_dialog_cluster(
    buttons: list[tuple[str, float, float, float, float, AXUIElementRef]],
) -> list[tuple[str, float, float, float, float, AXUIElementRef]] | None:
    """Find a cluster of equal-sized buttons aligned along a single axis.

    Two shapes qualify, both universal fingerprints of an iOS alert / action
    sheet:

    - Vertical: ≥2 buttons sharing x-origin and width, stacked with small
      vertical gaps. (iOS action sheet, 3+ button alert.)
    - Horizontal: ≥2 buttons sharing y-origin and height, sitting side-by-side
      with small horizontal gaps. (Standard 2-button alert: Allow / Don't Allow.)

    App UIs rarely satisfy either shape with ≥2 elements that share both
    cross-axis position AND cross-axis size.

    Returns the cluster (sorted along its axis) or None.
    """
    return (
        _find_axis_cluster(buttons, axis="vertical")
        or _find_axis_cluster(buttons, axis="horizontal")
    )


def _find_axis_cluster(
    buttons: list[tuple[str, float, float, float, float, AXUIElementRef]],
    axis: str,
) -> list[tuple[str, float, float, float, float, AXUIElementRef]] | None:
    """Find a cluster aligned along the given axis. See `_find_dialog_cluster`.

    For axis="vertical": cluster on (x, width); progress along y.
    For axis="horizontal": cluster on (y, height); progress along x.
    """
    if len(buttons) < _MIN_CLUSTER_SIZE:
        return None

    if axis == "vertical":
        align_idx, size_idx, progress_idx, progress_size_idx = 1, 3, 2, 4
    else:
        align_idx, size_idx, progress_idx, progress_size_idx = 2, 4, 1, 3

    from collections import defaultdict

    qa = max(1.0, _CLUSTER_X_TOLERANCE / 2)
    qs = max(1.0, _CLUSTER_W_TOLERANCE / 2)
    buckets: dict[tuple[int, int], list[tuple[str, float, float, float, float, AXUIElementRef]]] = defaultdict(list)
    for b in buttons:
        a = b[align_idx]
        s = b[size_idx]
        buckets[(int(round(a / qa)), int(round(s / qs)))].append(b)

    best: list[tuple[str, float, float, float, float, AXUIElementRef]] | None = None
    for items in buckets.values():
        if len(items) < _MIN_CLUSTER_SIZE:
            continue
        ref_a, ref_s = items[0][align_idx], items[0][size_idx]
        tight = [
            it for it in items
            if abs(it[align_idx] - ref_a) <= _CLUSTER_X_TOLERANCE
            and abs(it[size_idx] - ref_s) <= _CLUSTER_W_TOLERANCE
        ]
        if len(tight) < _MIN_CLUSTER_SIZE:
            continue
        tight.sort(key=lambda it: it[progress_idx])
        run: list[tuple[str, float, float, float, float, AXUIElementRef]] = [tight[0]]
        for it in tight[1:]:
            prev = run[-1]
            gap = it[progress_idx] - (prev[progress_idx] + prev[progress_size_idx])
            if -2.0 <= gap <= _CLUSTER_MAX_GAP:
                run.append(it)
            else:
                if len(run) >= _MIN_CLUSTER_SIZE and (best is None or len(run) > len(best)):
                    best = run
                run = [it]
        if len(run) >= _MIN_CLUSTER_SIZE and (best is None or len(run) > len(best)):
            best = run
    return best


# ---------------------------------------------------------------------------
# Per-app dialog detection (shared by detect_dialog and find_and_dismiss_dialog)
# ---------------------------------------------------------------------------


def _find_dialog_buttons_in_app(
    app_ref: AXUIElementRef,
) -> list[tuple[str, float, float, float, float, AXUIElementRef]]:
    """Return the AXButtons that make up the system dialog inside this Simulator
    app, or an empty list if no dialog is visible.

    Detection is structural — no title allowlist. The flow, scoped per window:

    1. For each AXWindow under the app, find its iOSContentGroup rect.
    2. Walk the window collecting AXButtons split by ancestry into "inside
       iOSContentGroup" (the iOS screen — plain app UI) and "outside"
       (sibling subtree — where SpringBoard renders permission dialogs).
    3. Filter geometrically: keep only buttons whose center sits within
       the iOSContentGroup rect. That excludes the Simulator's hardware
       buttons (Action, Volume Up, Home, etc.), which live in the bezel
       outside the iOS screen region. Per-window scoping is critical when
       multiple simulators are booted side-by-side, because window B's bezel
       buttons can geometrically overlap window A's iOSContentGroup.
    4. If AXSheet/AXDialog role is present, trust it and return all
       geometry-filtered buttons. Otherwise run the cluster heuristic only
       against the "outside iOSContentGroup" set — the same-x same-width
       shape inside the app subtree is too common in normal UI (toggle
       rows, segmented controls) to be treated as a dialog signal.

    Caller owns CFRetained refs in the returned tuples and must CFRelease each.
    """
    windows = _get_attr(app_ref, "AXWindows")
    if windows is None:
        return []
    try:
        if _cf.CFGetTypeID(windows) != _cf.CFArrayGetTypeID():
            return []
        count = _cf.CFArrayGetCount(windows)
        results: list[tuple[str, float, float, float, float, AXUIElementRef]] = []
        for i in range(count):
            w = _cf.CFArrayGetValueAtIndex(windows, i)
            if not w:
                continue
            results.extend(_find_dialog_buttons_in_window(w))
        return results
    finally:
        _cf.CFRelease(windows)


def _select_dialog_buttons(
    inside: list[tuple[str, float, float, float, float, object, int]],
    outside: list[tuple[str, float, float, float, float, object, int]],
    screen_rects: list[tuple[float, float, float, float]],
    sheet_present: bool,
) -> tuple[
    list[tuple[str, float, float, float, float, object, int]],
    list[tuple[str, float, float, float, float, object, int]],
]:
    """Pure decision over pre-collected button data. Returns (kept, dropped).

    Caller is responsible for CFRetaining elements in the input lists and
    CFReleasing every element in `dropped`. Splitting the decision from the
    AX walk lets the structural logic be exercised in unit tests without a
    live Simulator.

    Each button tuple is (title, x, y, w, h, element, screen_depth) where
    screen_depth is distance from the iOSContentGroup ancestor (1 = direct
    child).

    Rules:
    - Filter out buttons whose center sits outside every iOSContentGroup
      rect (Simulator hardware bezel, native AppKit menus, etc.).
    - When AXSheet/AXDialog role is present anywhere in the window, return
      every on-screen button regardless of subtree — the role is the signal.
    - Otherwise try the cluster heuristic in two passes:
      1. Sibling subtree (`outside`) — the original SpringBoard rendering
         path, no extra constraint.
      2. Direct children of iOSContentGroup (`inside` with depth==1) — the
         iOS 26.3 path where the dialog replaces the app's AX subtree.
         Two extra constraints to avoid app-UI false positives:
         - depth==1 excludes toggle rows / list cells (those nest under
           scroll views and lists).
         - cluster button width must be ≥ 50% of the iOSContentGroup width.
           Real alert/action-sheet buttons are wide; in-app stat clusters
           like "Followers, 28 / Following, 31" are narrow.
    """
    def _split_on_screen(buttons):
        keep, drop = [], []
        for tup in buttons:
            x, y, w, h = tup[1], tup[2], tup[3], tup[4]
            if any(_frame_inside((x, y, w, h), rect) for rect in screen_rects):
                keep.append(tup)
            else:
                drop.append(tup)
        return keep, drop

    on_screen_inside, off_screen_inside = _split_on_screen(inside)
    on_screen_outside, off_screen_outside = _split_on_screen(outside)
    dropped: list = list(off_screen_inside) + list(off_screen_outside)

    if sheet_present:
        return on_screen_inside + on_screen_outside, dropped

    cluster = _find_dialog_cluster(on_screen_outside)
    if cluster is not None:
        cluster_ids = {id(t[5]) for t in cluster}
        kept = [t for t in on_screen_outside if id(t[5]) in cluster_ids]
        dropped.extend(t for t in on_screen_outside if id(t[5]) not in cluster_ids)
        dropped.extend(on_screen_inside)
        return kept, dropped

    direct_children = [t for t in on_screen_inside if t[6] == 1]
    cluster = _find_dialog_cluster(direct_children)
    if cluster is not None and _cluster_is_dialog_width(cluster, screen_rects):
        cluster_ids = {id(t[5]) for t in cluster}
        kept = [t for t in on_screen_inside if id(t[5]) in cluster_ids]
        dropped.extend(t for t in on_screen_inside if id(t[5]) not in cluster_ids)
        dropped.extend(on_screen_outside)
        return kept, dropped

    dropped.extend(on_screen_inside)
    dropped.extend(on_screen_outside)
    return [], dropped


_INSIDE_FALLBACK_MIN_WIDTH_RATIO = 0.5


def _cluster_is_dialog_width(
    cluster: list[tuple[str, float, float, float, float, object, int]],
    screen_rects: list[tuple[float, float, float, float]],
) -> bool:
    """True when every button in the cluster is at least 50% as wide as the
    iOSContentGroup containing it. iOS alert and action-sheet buttons span
    most of their container; in-app clusters like stat counters or chip
    rows are narrow. Used to gate the inside-iOSContentGroup fallback only
    — the sibling-subtree path is already discriminating enough."""
    if not cluster or not screen_rects:
        return False
    for tup in cluster:
        bx, by, bw, bh = tup[1], tup[2], tup[3], tup[4]
        cx = bx + bw / 2
        cy = by + bh / 2
        containing = next(
            (rect for rect in screen_rects
             if rect[0] <= cx <= rect[0] + rect[2]
             and rect[1] <= cy <= rect[1] + rect[3]),
            None,
        )
        if containing is None:
            return False
        if bw < containing[2] * _INSIDE_FALLBACK_MIN_WIDTH_RATIO:
            return False
    return True


def _find_dialog_buttons_in_window(
    window: AXUIElementRef,
) -> list[tuple[str, float, float, float, float, AXUIElementRef, int]]:
    """Per-window scan. See `_find_dialog_buttons_in_app` for the strategy."""
    screen_rects: list[tuple[float, float, float, float]] = []
    _find_ios_screen_rects(window, screen_rects)
    if not screen_rects:
        return []

    sheet_present = _has_sheet_or_dialog_role(window)

    inside: list[tuple[str, float, float, float, float, AXUIElementRef, int]] = []
    outside: list[tuple[str, float, float, float, float, AXUIElementRef, int]] = []
    _collect_buttons_classified(window, False, inside, outside, max_depth=20)

    kept, dropped = _select_dialog_buttons(inside, outside, screen_rects, sheet_present)
    for tup in dropped:
        _cf.CFRelease(tup[5])
    return kept


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------


def find_and_dismiss_dialog(
    button_titles: list[str] | None = None,
    preferred_titles: list[str] | None = None,
    target_title: str | None = None,
) -> dict:
    """Find a system dialog in the Simulator and click a button to dismiss it.

    Enumerates every AXButton under the detected dialog so callers see every
    available option via the `buttons` field in the response. The choice of
    which button to tap is explicit:

    - `target_title`: tap this exact title if present; otherwise don't tap
      (return the full list so the caller can pick).
    - `preferred_titles`: tap the first match from this list. Defaults to the
      common "allow"-style titles. If nothing matches, return the full list
      without tapping — safer than picking an arbitrary button (Cancel,
      Don't Allow) that would deny the permission.
    """
    if preferred_titles is None:
        preferred_titles = ["Allow While Using App", "Allow Once", "Allow", "Open", "OK"]

    pids = _find_simulator_pids()
    if not pids:
        return {
            "dismissed": False, "button": None, "buttons": [],
            "method": "ax", "error": "No Simulator.app process found",
        }

    target_set: set[str] | None = set(button_titles) if button_titles else None
    all_found: list[tuple[str, AXUIElementRef, int]] = []  # (title, element, pid)

    for pid in pids:
        app_ref = _ax.AXUIElementCreateApplication(pid)
        if not app_ref:
            continue
        try:
            buttons = _find_dialog_buttons_in_app(app_ref)
            for title, _x, _y, _w, _h, el, _depth in buttons:
                if target_set is not None and title not in target_set:
                    _cf.CFRelease(el)
                    continue
                all_found.append((title, el, pid))
        finally:
            _cf.CFRelease(app_ref)

    button_names: list[str] = []
    seen: set[str] = set()
    for title, _, _ in all_found:
        if title not in seen:
            seen.add(title)
            button_names.append(title)

    if not all_found:
        return {
            "dismissed": False, "button": None, "buttons": [],
            "method": "ax", "error": "No dialog buttons found in Simulator",
        }

    chosen: tuple[str, AXUIElementRef, int] | None = None
    if target_title:
        for title, el, pid in all_found:
            if title == target_title:
                chosen = (title, el, pid)
                break
    else:
        for pref in preferred_titles:
            for title, el, pid in all_found:
                if title == pref:
                    chosen = (title, el, pid)
                    break
            if chosen:
                break

    if not chosen:
        reason = (
            f"No button matching target_title={target_title!r}"
            if target_title
            else "No preferred button found among dialog buttons"
        )
        for _, el, _ in all_found:
            _cf.CFRelease(el)
        return {
            "dismissed": False, "button": None, "buttons": button_names,
            "method": "ax", "error": reason,
        }

    title, element, pid = chosen
    action = _cfstr("AXPress")
    try:
        err = _ax.AXUIElementPerformAction(element, action)
        if err == kAXErrorSuccess:
            logger.info("AX dismissed dialog via button '%s' (pid %d)", title, pid)
            return {
                "dismissed": True, "button": title, "buttons": button_names,
                "method": "ax", "error": None,
            }
        return {
            "dismissed": False, "button": title, "buttons": button_names,
            "method": "ax", "error": f"AXPress failed with error code {err}",
        }
    finally:
        _cf.CFRelease(action)
        for _, el, _ in all_found:
            _cf.CFRelease(el)


def _has_visible_windows(app_ref: AXUIElementRef) -> bool:
    """Return True iff macOS Accessibility currently exposes ≥1 window for this
    application. AX returns an empty AXWindows array when the app is not the
    frontmost process — every read against a backgrounded app appears empty,
    which we can't distinguish from "really has no windows" without this check."""
    val = _get_attr(app_ref, "AXWindows")
    if val is None:
        return False
    try:
        if _cf.CFGetTypeID(val) != _cf.CFArrayGetTypeID():
            return False
        return _cf.CFArrayGetCount(val) > 0
    finally:
        _cf.CFRelease(val)


def detect_dialog() -> dict:
    """Check if a system dialog is visible in any Simulator window.

    Returns every AXButton title found under the detected dialog so callers
    see new iOS options (e.g. "Limit Access", "Allow Full Access") as soon
    as they appear — detection is structural, not name-matched.

    `inconclusive` is True when AX could not see Simulator's windows at all
    (typically because Simulator is not the focused macOS app). Distinct
    from `detected=False` so callers can render an honest "probe blind"
    hint rather than a confident "no dialog" claim.

    Returns:
        dict with keys: detected (bool), inconclusive (bool),
        buttons (list[str]), pids (list[int])
    """
    pids = _find_simulator_pids()
    if not pids:
        return {"detected": False, "inconclusive": False, "buttons": [], "pids": []}

    dialog_pids: list[int] = []
    button_titles_found: list[str] = []
    any_windows_visible = False

    for pid in pids:
        app_ref = _ax.AXUIElementCreateApplication(pid)
        if not app_ref:
            continue
        try:
            if _has_visible_windows(app_ref):
                any_windows_visible = True
            buttons = _find_dialog_buttons_in_app(app_ref)
            if not buttons:
                continue
            dialog_pids.append(pid)
            for title, _x, _y, _w, _h, el, _depth in buttons:
                if title not in button_titles_found:
                    button_titles_found.append(title)
                _cf.CFRelease(el)
        finally:
            _cf.CFRelease(app_ref)

    return {
        "detected": len(dialog_pids) > 0,
        "inconclusive": not any_windows_visible and not dialog_pids,
        "buttons": button_titles_found,
        "pids": dialog_pids,
    }

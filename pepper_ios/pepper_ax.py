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

# AXError codes
kAXErrorSuccess = 0


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

# Button titles we look for, in preference order
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

# Fast-path detection: AXDescriptions seen on common iOS permission prompts.
# Not exhaustive — dialogs whose buttons aren't in this set still get caught
# by the shape-based detector in _find_dialog_indicators.
_KNOWN_DIALOG_DESCS = frozenset(DEFAULT_BUTTON_TITLES)


def _find_ios_content_group(
    element: AXUIElementRef,
    depth: int = 0,
    max_depth: int = 8,
) -> AXUIElementRef | None:
    """Find the AXGroup with subrole "iOSContentGroup" — the root of the iOS
    content area inside a Simulator window. Returns a CFRetain'd ref that the
    caller must CFRelease, or None.

    Scoping searches to this subtree skips the Simulator's hardware buttons
    (Action, Volume Up, Sleep/Wake, Home, Rotate) and the macOS menu bar,
    which would otherwise show up as noise in button enumeration.
    """
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


def _find_dialog_indicators(
    element: AXUIElementRef,
    depth: int = 0,
    max_depth: int = 10,
) -> bool:
    """Check if the tree contains a system dialog.

    iOS simulator renders system dialogs inside AXGroup (not AXSheet/AXDialog).
    We detect them by looking for AXButton elements with known system dialog
    AXDescription values. A shape-based fallback was tried but the Simulator's
    AX tree flattens the iOS content (dialog buttons and app UI buttons appear
    as siblings) which made the shape heuristic unreliable — pending a better
    scoping approach, we stick with the fast allowlist check here.
    """
    role = _get_str_attr(element, "AXRole")
    if role in ("AXSheet", "AXDialog"):
        return True
    if role == "AXButton":
        desc = _get_str_attr(element, "AXDescription")
        if desc and desc in _KNOWN_DIALOG_DESCS:
            return True
    if depth >= max_depth:
        return False
    children = _get_children(element)
    for child in children:
        result = _find_dialog_indicators(child, depth + 1, max_depth)
        _cf.CFRelease(child)
        if result:
            return True
    return False


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------


def find_and_dismiss_dialog(
    button_titles: list[str] | None = None,
    preferred_titles: list[str] | None = None,
    target_title: str | None = None,
) -> dict:
    """Find a system dialog in the Simulator and click a button to dismiss it.

    Enumerates every AXButton under the detected dialog (no title allowlist),
    so callers see every available option via the `buttons` field in the
    response. The choice of which button to tap is explicit:

    - `target_title`: tap this exact title if present; otherwise don't tap
      (return the full list so the caller can pick).
    - `preferred_titles`: tap the first match from this list. Defaults to the
      common "allow"-style titles. If nothing matches, return the full list
      without tapping — safer than picking an arbitrary button (Cancel,
      Don't Allow) that would deny the permission.

    Args:
        button_titles: If given, only return/consider buttons with these
            titles. Default (None) enumerates every button.
        preferred_titles: Titles to try tapping in order. Ignored when
            `target_title` is set.
        target_title: Exact title to tap. Takes precedence over
            preferred_titles.

    Returns:
        dict with keys:
          dismissed: bool
          button: str | None (title of button that was tapped, if any)
          buttons: list[str] (all button titles found under the dialog)
          method: "ax"
          error: str | None
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
            if not _find_dialog_indicators(app_ref):
                continue
            # Scope button search to iOSContentGroup to skip Simulator
            # hardware buttons and macOS chrome. Fall back to whole tree if
            # the iOS content group isn't found (older sim builds).
            search_root = _find_ios_content_group(app_ref) or app_ref
            found: list[tuple[str, AXUIElementRef]] = []
            _find_buttons_recursive(search_root, target_set, found)
            if search_root is not app_ref:
                _cf.CFRelease(search_root)
            for title, el in found:
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
        # Don't fall back to tapping an arbitrary button — a "Cancel" or
        # "Don't Allow" tap here would deny the permission silently. Let the
        # caller decide by reading `buttons` and calling again with
        # target_title.
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


def detect_dialog() -> dict:
    """Check if a system dialog is visible in any Simulator window.

    Returns every AXButton title under the detected dialog — not filtered
    against a hardcoded allowlist — so callers see new iOS options (e.g.
    "Limit Access", "Allow Access to All Photos") as soon as they appear.

    Returns:
        dict with keys: detected (bool), buttons (list[str]), pids (list[int])
    """
    pids = _find_simulator_pids()
    if not pids:
        return {"detected": False, "buttons": [], "pids": []}

    dialog_pids = []
    button_titles_found: list[str] = []

    for pid in pids:
        app_ref = _ax.AXUIElementCreateApplication(pid)
        if not app_ref:
            continue
        try:
            if not _find_dialog_indicators(app_ref):
                continue
            dialog_pids.append(pid)
            # Scope enumeration to iOSContentGroup to skip Simulator hardware
            # buttons and macOS chrome.
            search_root = _find_ios_content_group(app_ref) or app_ref
            found: list[tuple[str, AXUIElementRef]] = []
            _find_buttons_recursive(search_root, None, found)  # None = no title filter
            if search_root is not app_ref:
                _cf.CFRelease(search_root)
            for title, el in found:
                if title not in button_titles_found:
                    button_titles_found.append(title)
                _cf.CFRelease(el)
        finally:
            _cf.CFRelease(app_ref)

    return {
        "detected": len(dialog_pids) > 0,
        "buttons": button_titles_found,
        "pids": dialog_pids,
    }

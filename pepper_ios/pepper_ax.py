"""pepper_ax -- macOS Accessibility API (AXUIElement) helper for Simulator dialog dismissal.

Uses ctypes to call macOS Accessibility APIs directly — no pyobjc dependency.
Finds the Simulator.app window, walks the accessibility tree to locate system
dialog buttons ("Allow", "Allow While Using App", etc.), and clicks them.
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
    "OK",
    "Continue",
    "Not Now",
    "Don\u2019t Allow",  # curly apostrophe
    "Don't Allow",  # straight apostrophe
]

# AXRole values for clickable elements
_BUTTON_ROLES = {"AXButton"}


def _find_buttons_recursive(
    element: AXUIElementRef,
    target_titles: set[str],
    found: list[tuple[str, AXUIElementRef]],
    depth: int = 0,
    max_depth: int = 15,
):
    """Walk the accessibility tree and collect buttons matching target titles."""
    if depth > max_depth:
        return

    role = _get_str_attr(element, "AXRole")
    if role in _BUTTON_ROLES:
        # Check both AXTitle and AXDescription — iOS simulator dialogs
        # expose button labels as AXDescription, not AXTitle.
        title = _get_str_attr(element, "AXTitle")
        if not title or title not in target_titles:
            title = _get_str_attr(element, "AXDescription")
        if title and title in target_titles:
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
    """Check if the tree contains a dialog.

    iOS simulator renders permission dialogs inside AXGroup (not AXSheet/AXDialog).
    We detect them by looking for AXButton elements with permission-related
    AXDescription values (Allow, Don't Allow, etc.) inside the iOSContentGroup.
    """
    role = _get_str_attr(element, "AXRole")
    if role in ("AXSheet", "AXDialog"):
        return True
    # iOS sim dialogs: buttons with permission text in AXDescription
    if role == "AXButton":
        desc = _get_str_attr(element, "AXDescription")
        if desc and desc in ("Allow", "Allow Once", "Allow While Using App", "Don\u2019t Allow", "Don't Allow", "OK"):
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
) -> dict:
    """Find a system dialog in the Simulator and click a button to dismiss it.

    Args:
        button_titles: Buttons to search for. Defaults to DEFAULT_BUTTON_TITLES.
        preferred_titles: Subset to prefer clicking (e.g. ["Allow While Using App", "Allow"]).
            If None, uses the first 4 of DEFAULT_BUTTON_TITLES (the "allow" ones).

    Returns:
        dict with keys: dismissed (bool), button (str|None), method (str), error (str|None)
    """
    if button_titles is None:
        button_titles = list(DEFAULT_BUTTON_TITLES)
    if preferred_titles is None:
        preferred_titles = ["Allow While Using App", "Allow Once", "Allow", "OK"]

    pids = _find_simulator_pids()
    if not pids:
        return {"dismissed": False, "button": None, "method": "ax", "error": "No Simulator.app process found"}

    target_set = set(button_titles)
    all_found: list[tuple[str, AXUIElementRef, int]] = []  # (title, element, pid)

    for pid in pids:
        app_ref = _ax.AXUIElementCreateApplication(pid)
        if not app_ref:
            continue
        try:
            # Check if there's a dialog/sheet before doing full button scan
            if not _find_dialog_indicators(app_ref):
                continue
            found: list[tuple[str, AXUIElementRef]] = []
            _find_buttons_recursive(app_ref, target_set, found)
            for title, el in found:
                all_found.append((title, el, pid))
        finally:
            _cf.CFRelease(app_ref)

    if not all_found:
        return {"dismissed": False, "button": None, "method": "ax", "error": "No dialog buttons found in Simulator"}

    # Pick best button: prefer preferred_titles in order
    chosen = None
    for pref in preferred_titles:
        for title, el, pid in all_found:
            if title == pref:
                chosen = (title, el, pid)
                break
        if chosen:
            break

    # Fall back to first found button
    if not chosen:
        chosen = all_found[0]

    title, element, pid = chosen
    action = _cfstr("AXPress")
    try:
        err = _ax.AXUIElementPerformAction(element, action)
        if err == kAXErrorSuccess:
            logger.info("AX dismissed dialog via button '%s' (pid %d)", title, pid)
            return {"dismissed": True, "button": title, "method": "ax", "error": None}
        return {
            "dismissed": False,
            "button": title,
            "method": "ax",
            "error": f"AXPress failed with error code {err}",
        }
    finally:
        _cf.CFRelease(action)
        for _, el, _ in all_found:
            _cf.CFRelease(el)


def detect_dialog() -> dict:
    """Check if a system dialog is visible in any Simulator window.

    Returns:
        dict with keys: detected (bool), buttons (list[str]), pids (list[int])
    """
    pids = _find_simulator_pids()
    if not pids:
        return {"detected": False, "buttons": [], "pids": []}

    target_set = set(DEFAULT_BUTTON_TITLES)
    dialog_pids = []
    button_titles_found = []

    for pid in pids:
        app_ref = _ax.AXUIElementCreateApplication(pid)
        if not app_ref:
            continue
        try:
            if not _find_dialog_indicators(app_ref):
                continue
            dialog_pids.append(pid)
            found: list[tuple[str, AXUIElementRef]] = []
            _find_buttons_recursive(app_ref, target_set, found)
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

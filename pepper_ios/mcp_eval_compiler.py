"""Compile Swift source into a dylib for injection into a running simulator app.

Handles SDK detection, app module resolution, and swiftc invocation.
Each compilation produces a uniquely-named dylib to avoid dlopen caching."""

from __future__ import annotations

import hashlib
import os
import subprocess
import tempfile
import time

# Persistent temp dir for eval artifacts
EVAL_DIR = os.path.join(tempfile.gettempdir(), "pepper-eval")

# PepperEvalSDK.swift — compiled alongside eval code for Pepper.* API access
_REPO_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
_SDK_PATH = os.path.join(_REPO_DIR, "dylib", "eval", "PepperEvalSDK.swift")
os.makedirs(EVAL_DIR, exist_ok=True)

# REPL wrapper template — user writes an expression, we wrap it
REPL_TEMPLATE = """\
import Foundation
import UIKit
import SwiftUI
{app_import}

// Retain the last result string so its pointer stays valid after return.
private var __pepperLastResult: UnsafeMutablePointer<CChar>?

@_cdecl("pepper_eval")
public func pepperEval() -> UnsafePointer<CChar> {{
    // Free previous result
    __pepperLastResult.map {{ free($0) }}
    let __result: Any = {{
        {code}
    }}()
    let __str = String(describing: __result)
    __pepperLastResult = strdup(__str)
    return UnsafePointer(__pepperLastResult!)
}}
"""

# Full mode template — user writes complete function body
FULL_TEMPLATE = """\
import Foundation
import UIKit
import SwiftUI
{app_import}

@_cdecl("pepper_eval")
public func pepperEval() -> UnsafePointer<CChar> {{
{code}
}}
"""


def _detect_sdk() -> tuple[str, str, str]:
    """Detect simulator SDK path, target triple, and architecture."""
    arch = subprocess.check_output(["uname", "-m"]).decode().strip()
    sdk_name = "iphonesimulator"
    sdk_path = subprocess.check_output(
        ["xcrun", "--sdk", sdk_name, "--show-sdk-path"]
    ).decode().strip()
    sdk_ver = subprocess.check_output(
        ["xcrun", "--sdk", sdk_name, "--show-sdk-version"]
    ).decode().strip()
    ios_ver = sdk_ver.split(".")[0] + ".0"

    target = f"arm64-apple-ios{ios_ver}-simulator" if arch == "arm64" else f"x86_64-apple-ios{ios_ver}-simulator"

    return sdk_path, target, arch


def _find_app_module(bundle_id: str | None, scheme: str | None) -> tuple[str | None, str | None, str | None]:
    """Find the app's .swiftmodule and binary from DerivedData.

    Scans every DerivedData-* worktree in /tmp plus the default Xcode
    DerivedData, collects all products dirs that contain a matching
    .swiftmodule, and picks the most recently modified. This matters when
    multiple worktrees have built the same scheme — the first match isn't
    necessarily the build the user is currently running, and picking a
    stale/partial DerivedData can yield empty dependency frameworks (e.g.
    Lottie.framework with no .swiftinterface, causing 'missing required
    module' errors).

    Returns (module_dir, binary_dir, module_name) or (None, None, None) if
    not found.
    """
    if not scheme and not bundle_id:
        return None, None, None

    # Collect every DerivedData root, then every products dir under them.
    search_dirs: list[str] = []
    try:
        for entry in os.scandir("/tmp"):
            if entry.name.startswith("DerivedData-") and entry.is_dir():
                search_dirs.append(entry.path)
    except OSError:
        pass

    default_dd = os.path.expanduser("~/Library/Developer/Xcode/DerivedData")
    if os.path.isdir(default_dd):
        search_dirs.append(default_dd)

    # For each products dir, look for a matching .swiftmodule and record its
    # mtime. Pick the newest.
    candidates: list[tuple[float, str, str]] = []  # (mtime, products_dir, module_name)
    for dd_root in search_dirs:
        for products_dir in _find_all_products_dirs(dd_root):
            if scheme:
                sm = os.path.join(products_dir, f"{scheme}.swiftmodule")
                if os.path.isdir(sm):
                    try:
                        candidates.append((os.path.getmtime(sm), products_dir, scheme))
                        continue
                    except OSError:
                        pass
            try:
                for entry in os.scandir(products_dir):
                    if entry.name.endswith(".swiftmodule") and entry.is_dir():
                        mod_name = entry.name.removesuffix(".swiftmodule")
                        if not scheme or mod_name == scheme:
                            try:
                                candidates.append((entry.stat().st_mtime, products_dir, mod_name))
                            except OSError:
                                pass
            except OSError:
                continue

    if not candidates:
        return None, None, None

    candidates.sort(reverse=True)  # newest first
    _, products_dir, mod_name = candidates[0]
    return products_dir, products_dir, mod_name


def _xcframework_sim_search_paths(products_dir: str) -> list[tuple[str | None, str | None]]:
    """Return (framework_search_path, header_search_path) tuples for every
    xcframework's simulator slice under SourcePackages/artifacts.

    Handles both layouts:
    - Framework slice: <slice>/Foo.framework → add <slice> as -F
    - Bare-headers slice: <slice>/Headers/module.modulemap → add <slice>/Headers as -I

    products_dir is .../Build/Products/Debug-iphonesimulator; SourcePackages
    is a sibling of Build.
    """
    results: list[tuple[str | None, str | None]] = []
    # Navigate up to DerivedData root: .../Build/Products/<config> → parent × 3
    try:
        dd_root = os.path.abspath(os.path.join(products_dir, "..", "..", ".."))
    except Exception:
        return results
    artifacts = os.path.join(dd_root, "SourcePackages", "artifacts")
    if not os.path.isdir(artifacts):
        return results
    try:
        for pkg_entry in os.scandir(artifacts):
            if not pkg_entry.is_dir():
                continue
            for name_entry in os.scandir(pkg_entry.path):
                if not name_entry.is_dir():
                    continue
                for xcf_entry in os.scandir(name_entry.path):
                    if not xcf_entry.is_dir() or not xcf_entry.name.endswith(".xcframework"):
                        continue
                    for slice_entry in os.scandir(xcf_entry.path):
                        if not slice_entry.is_dir() or "simulator" not in slice_entry.name:
                            continue
                        slice_path = slice_entry.path
                        has_framework = any(
                            e.name.endswith(".framework") for e in os.scandir(slice_path) if e.is_dir()
                        )
                        headers = os.path.join(slice_path, "Headers")
                        has_headers = os.path.isdir(headers)
                        results.append(
                            (slice_path if has_framework else None, headers if has_headers else None)
                        )
    except OSError:
        pass
    return results


def _find_all_products_dirs(dd_root: str) -> list[str]:
    """Find all Build/Products/Debug-iphonesimulator dirs under a DerivedData root."""
    results = []
    # Check if dd_root itself has Build/Products (worktree-isolated DerivedData)
    direct = os.path.join(dd_root, "Build", "Products", "Debug-iphonesimulator")
    if os.path.isdir(direct):
        results.append(direct)
    # DerivedData structure: DerivedData/ProjectName-hash/Build/Products/Debug-iphonesimulator/
    try:
        for entry in os.scandir(dd_root):
            if not entry.is_dir():
                continue
            products = os.path.join(entry.path, "Build", "Products", "Debug-iphonesimulator")
            if os.path.isdir(products):
                results.append(products)
    except OSError:
        pass
    return results


def compile_eval(
    code: str,
    mode: str = "expr",
    bundle_id: str | None = None,
    scheme: str | None = None,
    sim_udid: str | None = None,
) -> tuple[bool, str, str | None]:
    """Compile Swift code into a dylib for eval injection.

    Args:
        code: Swift source code (expression for mode=expr, function body for mode=full)
        mode: "expr" wraps in REPL template, "full" uses code as pepperEval body
        bundle_id: App bundle ID for module resolution
        scheme: Xcode scheme name for module resolution
        sim_udid: Simulator UDID (for placing dylib in accessible location)

    Returns:
        (success, dylib_path_or_error, compile_output)
    """
    sdk_path, target, arch = _detect_sdk()

    # Find app module for import
    module_dir, binary_dir, module_name = _find_app_module(bundle_id, scheme)
    app_import = f"@testable import {module_name}" if module_name else ""

    # Generate source
    if mode == "expr":
        source = REPL_TEMPLATE.format(app_import=app_import, code=code)
    else:
        # Indent user code for the function body
        indented = "\n".join("    " + line for line in code.splitlines())
        source = FULL_TEMPLATE.format(app_import=app_import, code=indented)

    # Unique name based on content hash + timestamp
    code_hash = hashlib.md5(source.encode()).hexdigest()[:8]
    timestamp = int(time.time() * 1000) % 100000
    dylib_name = f"pepper_eval_{code_hash}_{timestamp}"

    source_path = os.path.join(EVAL_DIR, f"{dylib_name}.swift")
    dylib_path = os.path.join(EVAL_DIR, f"{dylib_name}.dylib")

    # Write source
    with open(source_path, "w") as f:
        f.write(source)

    # Build swiftc command
    cmd = [
        "xcrun", "-sdk", "iphonesimulator", "swiftc",
        "-target", target,
        "-sdk", sdk_path,
        "-emit-library",
        "-o", dylib_path,
        "-Onone",
        "-enable-testing",
        "-framework", "UIKit",
        "-framework", "Foundation",
        "-framework", "SwiftUI",
    ]

    # Allow unresolved symbols — they'll resolve at dlopen time from the host process
    cmd.extend(["-Xlinker", "-undefined", "-Xlinker", "dynamic_lookup"])

    # Add app module and dependency search paths. @testable import of the app
    # module pulls in its transitive imports — Lottie, GoogleMaps, etc. —
    # which swiftc must be able to resolve, or compilation fails with
    # "missing required module 'X'". SPM packages ship in several layouts,
    # so we pass a fan-out of search paths:
    #   -I <products>                   standalone .swiftmodule dirs
    #   -F <products>                   framework products (Apollo, etc.)
    #   -F <products>/PackageFrameworks SPM-built framework products
    #   -F <slice>                      xcframework sim slices with .framework
    #   -I <slice>/Headers              xcframework sim slices with bare headers
    # Slice paths come from walking SourcePackages/artifacts/*/*/*.xcframework/
    # and picking directories whose name contains "simulator".
    if module_dir:
        cmd.extend(["-I", module_dir])
        cmd.extend(["-F", module_dir])
        package_fw = os.path.join(module_dir, "PackageFrameworks")
        if os.path.isdir(package_fw):
            cmd.extend(["-F", package_fw])
        for frame_path, include_path in _xcframework_sim_search_paths(module_dir):
            if frame_path:
                cmd.extend(["-F", frame_path])
            if include_path:
                cmd.extend(["-I", include_path])

    # Include PepperEvalSDK for Pepper.* API access
    if os.path.exists(_SDK_PATH):
        cmd.append(_SDK_PATH)

    cmd.append(source_path)

    # Compile
    start = time.time()
    result = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
    elapsed_ms = int((time.time() - start) * 1000)

    if result.returncode != 0:
        error_output = result.stderr.strip() or result.stdout.strip()
        # Clean up error paths for readability
        error_output = error_output.replace(EVAL_DIR + "/", "")
        return False, f"Compilation failed ({elapsed_ms}ms):\n{error_output}", None

    # Verify dylib was created
    if not os.path.exists(dylib_path):
        return False, "Compiler returned success but dylib not found", None

    dylib_size = os.path.getsize(dylib_path)

    # If sim_udid provided, copy to simulator's tmp dir for accessibility
    if sim_udid:
        sim_tmp = _sim_tmp_dir(sim_udid)
        if sim_tmp:
            sim_dylib = os.path.join(sim_tmp, f"{dylib_name}.dylib")
            subprocess.run(["cp", dylib_path, sim_dylib], check=True)
            dylib_path = sim_dylib

    return True, dylib_path, f"Compiled in {elapsed_ms}ms ({dylib_size} bytes)"


def _sim_tmp_dir(udid: str) -> str | None:
    """Get the simulator's /tmp directory on the host filesystem."""
    try:
        result = subprocess.run(
            ["xcrun", "simctl", "get_app_container", udid, "com.apple.Preferences", "data"],
            capture_output=True, text=True,
        )
        if result.returncode == 0:
            # Container path like /Users/.../data/Containers/Data/Application/UUID
            # Simulator tmp is at the device root: .../data/../../../tmp
            container = result.stdout.strip()
            # Navigate to device root
            parts = container.split("/")
            # Find "data" directory at device level
            for i, part in enumerate(parts):
                if part == "Containers":
                    device_root = "/".join(parts[:i])
                    tmp_dir = os.path.join(device_root, "tmp")
                    os.makedirs(tmp_dir, exist_ok=True)
                    return tmp_dir
    except (subprocess.SubprocessError, OSError):
        pass

    # Fallback: use shared /tmp (works for simulators since they share filesystem)
    return EVAL_DIR

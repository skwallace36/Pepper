"""MCP tool for dynamic Swift eval — compile and execute Swift code inside a running app."""

from __future__ import annotations

from pydantic import Field

from .mcp_eval_compiler import compile_eval
from .pepper_common import get_config


def register_eval_tools(mcp, resolve_and_send):
    """Register the app_eval tool."""

    @mcp.tool(name="app_eval")
    async def app_eval(
        code: str = Field(description="Swift code to compile and execute inside the running app"),
        mode: str = Field(
            default="expr",
            description="'expr': code is a Swift expression (auto-wrapped). 'full': code is the full pepperEval() function body (must return a C string)",
        ),
        simulator: str | None = Field(default=None, description="Simulator UDID"),
    ) -> str:
        """Compile and execute arbitrary Swift code inside the running app process.

Use this when existing Pepper tools can't do what you need — runtime introspection,
calling app methods, complex state mutation, accessing internal types, or any logic
that requires real Swift execution.

In expr mode (default), write a Swift expression. It runs inside the app and the
result is returned as a string:

  UIApplication.shared.connectedScenes.count
  Mirror(reflecting: someObject).children.map { "\\($0.label): \\($0.value)" }
  AppState().tapCount  // access internal app types via @testable import

In full mode, write the complete function body. Must return UnsafePointer<CChar>:

  let count = UIApplication.shared.connectedScenes.count
  let s = strdup("scenes: \\(count)")!
  return UnsafePointer(s)

You have full access to:
- UIKit, SwiftUI, Foundation, and all loaded frameworks
- The app's own types (internal classes, structs, enums) via @testable import
- ObjC runtime (objc_copyClassList, class_getInstanceMethod, etc.)
- Mirror for reflecting on any object
- KVC for reading ObjC properties
- The app's live objects, view hierarchy, and state

Compile time: ~500ms cached, ~2s cold. Each eval is a unique dylib."""

        cfg = get_config()
        bundle_id = cfg.get("bundle_id")
        scheme = cfg.get("scheme")

        # Step 1: Compile
        success, result, compile_info = compile_eval(
            code=code,
            mode=mode,
            bundle_id=bundle_id,
            scheme=scheme,
            sim_udid=simulator,
        )

        if not success:
            return f"Compile error:\n{result}"

        dylib_path = result

        # Step 2: Send to dylib for execution
        params = {"dylib_path": dylib_path, "action": "run"}
        try:
            response = await resolve_and_send(simulator, "eval", params, timeout=30)
        except Exception as e:
            return f"Compiled OK ({compile_info}) but execution failed: {e}"

        # Format output
        parts = [f"[{compile_info}]"]
        parts.append(response)
        return "\n".join(parts)

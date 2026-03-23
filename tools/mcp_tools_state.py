"""State inspection tool definitions for Pepper MCP.

Tool definitions for: vars_inspect, defaults, clipboard, keychain, cookies.
"""

import json

from pydantic import Field


def try_parse_json(value):
    """Try to parse a string as JSON for proper typing (bool, int, dict, list).
    Returns the parsed value on success, or the original string on failure."""
    if value is None:
        return None
    try:
        return json.loads(value)
    except (json.JSONDecodeError, TypeError):
        return value


def register_state_tools(mcp, resolve_and_send):
    """Register state inspection tools on the given MCP server.

    Args:
        mcp: FastMCP server instance.
        resolve_and_send: async (simulator, cmd, params?, timeout?) -> str
    """

    @mcp.tool()
    async def vars_inspect(
        simulator: str | None = Field(default=None, description="Simulator UDID"),
        action: str = Field(description="Action: list, dump, mirror, set, discover"),
        class_name: str | None = Field(default=None, description="ViewModel class name (for dump/mirror/set)"),
        path: str | None = Field(default=None, description="Property path (for set, e.g. 'MyVM.flag')"),
        value: str | None = Field(default=None, description="Value to set (for set action)"),
    ) -> str:
        """Check or change property values at runtime WITHOUT adding print statements or rebuilding.
        - list: show all tracked ViewModels
        - dump: show @Published properties (use this to check state instead of adding logs!)
        - mirror: full property dump including private state
        - set: mutate a property live (triggers SwiftUI re-render, great for testing theories)
        - discover: re-scan for ViewModels"""
        params: dict = {"action": action}
        if class_name:
            params["class"] = class_name
        if path:
            params["path"] = path
        if value is not None:
            params["value"] = try_parse_json(value)
        return await resolve_and_send(simulator, "vars", params)

    @mcp.tool()
    async def defaults(
        simulator: str | None = Field(default=None, description="Simulator UDID"),
        action: str = Field(default="list", description="Action: list, get, set, delete"),
        key: str | None = Field(default=None, description="UserDefaults key (for get/set/delete)"),
        value: str | None = Field(default=None, description="Value to set (JSON: string, number, bool, array, dict)"),
        prefix: str | None = Field(default=None, description="Filter keys by prefix (for list)"),
        suite: str | None = Field(default=None, description="UserDefaults suite name (default: standard)"),
    ) -> str:
        """Read and write NSUserDefaults — the app's persistent key-value storage.
        Use this to control app behavior without UI: set debug flags, enable test modes,
        bypass onboarding, inject configuration. Many apps read feature toggles, debug
        settings, and cached state from UserDefaults.

        Actions:
        - list: show all keys (optionally filtered by prefix — useful for finding app-specific keys)
        - get: read a specific key's value and type
        - set: write a value (parsed as JSON — supports string, number, bool, array, dict)
        - delete: remove a key

        Related tools: vars_inspect (runtime ViewModel state), keychain (stored credentials),
        flags (feature flag overrides via network interception)."""
        params: dict = {"action": action}
        if key:
            params["key"] = key
        if prefix:
            params["prefix"] = prefix
        if suite:
            params["suite"] = suite
        if value is not None:
            params["value"] = try_parse_json(value)
        return await resolve_and_send(simulator, "defaults", params)

    @mcp.tool()
    async def clipboard(
        simulator: str | None = Field(default=None, description="Simulator UDID"),
        action: str = Field(default="get", description="Action: get, set, clear"),
        value: str | None = Field(default=None, description="String to copy to clipboard (for set)"),
    ) -> str:
        """Read or write the device clipboard (UIPasteboard).
        - get: read current clipboard contents (string, URL, types)
        - set: copy a string to clipboard
        - clear: empty the clipboard"""
        params: dict = {"action": action}
        if value is not None:
            params["value"] = value
        return await resolve_and_send(simulator, "clipboard", params)

    @mcp.tool()
    async def keychain(
        simulator: str | None = Field(default=None, description="Simulator UDID"),
        action: str = Field(default="list", description="Action: list, get, set, delete, clear"),
        service: str | None = Field(default=None, description="Keychain service name (for get/set/delete, or filter for list)"),
        account: str | None = Field(default=None, description="Keychain account (for get/set/delete)"),
        value: str | None = Field(default=None, description="Value to store (for set)"),
    ) -> str:
        """Inspect and modify Keychain items — stored credentials, tokens, secrets.
        - list: show all keychain items (service, account, access group)
        - get: read a specific item's value
        - set: add or update an item
        - delete: remove an item by service (+ optional account)
        - clear: delete ALL generic password items"""
        params: dict = {"action": action}
        if service:
            params["service"] = service
        if account:
            params["account"] = account
        if value is not None:
            params["value"] = value
        return await resolve_and_send(simulator, "keychain", params)

    @mcp.tool()
    async def cookies(
        simulator: str | None = Field(default=None, description="Simulator UDID"),
        action: str = Field(default="list", description="Action: list, get, delete, clear"),
        domain: str | None = Field(default=None, description="Cookie domain filter"),
        name: str | None = Field(default=None, description="Cookie name (for delete)"),
    ) -> str:
        """Inspect HTTP cookies from HTTPCookieStorage.
        - list: show all cookies (optionally filtered by domain)
        - get: get cookies for a specific domain
        - delete: remove a cookie by name + domain
        - clear: delete all cookies"""
        params: dict = {"action": action}
        if domain:
            params["domain"] = domain
        if name:
            params["name"] = name
        return await resolve_and_send(simulator, "cookies", params)

    @mcp.tool()
    async def undo_manager(
        simulator: Optional[str] = Field(default=None, description="Simulator UDID"),
        action: str = Field(default="list", description="Action: list, status, undo, redo"),
        index: Optional[int] = Field(default=None, description="Manager index from 'list' (default: 0, the first found)"),
    ) -> str:
        """Inspect and control NSUndoManager — query undo/redo stack state and trigger undo/redo.
        Use this to verify that user actions are properly registered as undoable, test undo/redo
        flows, and debug undo stack issues in document-based or text-heavy apps.

        Actions:
        - list: find all NSUndoManager instances (via responder chain + heap scan), show owner and state
        - status: detailed state of a specific manager (canUndo, canRedo, action names, grouping level)
        - undo: trigger undo on a manager (reports what was undone)
        - redo: trigger redo on a manager (reports what was redone)

        Related tools: vars_inspect (runtime state), heap (object discovery)."""
        params: dict = {"action": action}
        if index is not None:
            params["index"] = index
        return await resolve_and_send(simulator, "undo", params)

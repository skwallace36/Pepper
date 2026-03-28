"""State inspection tool definitions for Pepper MCP.

Tool definitions for: vars_inspect, defaults, clipboard, keychain, cookies.
"""

from __future__ import annotations

from pydantic import Field

from .pepper_commands import (
    CMD_CLIPBOARD,
    CMD_COOKIES,
    CMD_COREDATA,
    CMD_DEFAULTS,
    CMD_KEYCHAIN,
    CMD_SANDBOX,
    CMD_STORAGE,
    CMD_UNDO,
    CMD_VARS,
)
from .pepper_common import try_parse_json


def register_state_tools(mcp, resolve_and_send):
    """Register state inspection tools on the given MCP server.

    Args:
        mcp: FastMCP server instance.
        resolve_and_send: async (simulator, cmd, params?, timeout?) -> dict
    """

    @mcp.tool()
    async def vars_inspect(
        simulator: str | None = Field(default=None, description="Simulator UDID"),
        action: str = Field(description="Action: list, dump, mirror, set, discover"),
        class_name: str | None = Field(default=None, description="ViewModel class name (for dump/mirror/set)"),
        path: str | None = Field(default=None, description="Property path (for set, e.g. 'MyVM.flag')"),
        value: str | None = Field(default=None, description="Value to set (for set action)"),
    ) -> str:
        """Check or change ViewModel @Published properties at runtime — no rebuild needed.
        Use vars_inspect for SwiftUI/MVVM state. Use `heap` for arbitrary ObjC objects
        and singletons. Use `read_element` for UI element values (text, toggle state).

        Actions:
        - list: show all tracked ViewModels
        - dump: show @Published properties (check state instead of adding print statements)
        - mirror: full property dump including private/internal state
        - set: mutate a property live (triggers SwiftUI re-render — great for testing theories)
        - discover: re-scan for ViewModels after navigation changes

        Related tools: heap (any ObjC object), read_element (UI element value/state),
        defaults (persisted key-value storage)."""
        params: dict = {"action": action}
        if class_name:
            params["class"] = class_name
        if path:
            params["path"] = path
        if value is not None:
            params["value"] = try_parse_json(value)
        return await resolve_and_send(simulator, CMD_VARS, params)

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
        return await resolve_and_send(simulator, CMD_DEFAULTS, params)

    @mcp.tool()
    async def clipboard(
        simulator: str | None = Field(default=None, description="Simulator UDID"),
        action: str = Field(default="get", description="Action: get, set, clear"),
        value: str | None = Field(default=None, description="String to copy to clipboard (for set)"),
    ) -> str:
        """Read or write the iOS simulator clipboard (UIPasteboard.general).
        Useful for injecting test data into paste fields or verifying copy behavior.

        Actions:
        - get: read current clipboard contents (string, URL, detected types)
        - set: copy a string to clipboard (appears in any app's paste action)
        - clear: empty the clipboard"""
        params: dict = {"action": action}
        if value is not None:
            params["value"] = value
        return await resolve_and_send(simulator, CMD_CLIPBOARD, params)

    @mcp.tool()
    async def keychain(
        simulator: str | None = Field(default=None, description="Simulator UDID"),
        action: str = Field(default="list", description="Action: list, get, set, delete, clear"),
        service: str | None = Field(
            default=None, description="Keychain service name (for get/set/delete, or filter for list)"
        ),
        account: str | None = Field(default=None, description="Keychain account (for get/set/delete)"),
        value: str | None = Field(default=None, description="Value to store (for set)"),
    ) -> str:
        """Inspect and modify iOS Keychain items — stored credentials, auth tokens, API secrets.
        Reads kSecClassGenericPassword items from the app's Keychain access group.

        Actions:
        - list: show all keychain items (service, account, access group)
        - get: read a specific item's value by service + account
        - set: add or update an item
        - delete: remove an item by service (+ optional account)
        - clear: delete ALL generic password items

        Related tools: defaults (app preferences, not secrets), cookies (HTTP session tokens)."""
        params: dict = {"action": action}
        if service:
            params["service"] = service
        if account:
            params["account"] = account
        if value is not None:
            params["value"] = value
        return await resolve_and_send(simulator, CMD_KEYCHAIN, params)

    @mcp.tool()
    async def cookies(
        simulator: str | None = Field(default=None, description="Simulator UDID"),
        action: str = Field(default="list", description="Action: list, get, delete, clear"),
        domain: str | None = Field(default=None, description="Cookie domain filter"),
        name: str | None = Field(default=None, description="Cookie name (for delete)"),
    ) -> str:
        """Inspect HTTP cookies from HTTPCookieStorage.shared — session tokens, tracking IDs,
        consent flags. Useful for debugging auth flows and verifying cookie-based sessions.

        Actions:
        - list: show all cookies (optionally filtered by domain)
        - get: get cookies for a specific domain with name, value, path, expiry
        - delete: remove a cookie by name + domain
        - clear: delete all cookies (useful for testing logged-out state)

        Related tools: keychain (stored credentials), network (HTTP request/response inspection)."""
        params: dict = {"action": action}
        if domain:
            params["domain"] = domain
        if name:
            params["name"] = name
        return await resolve_and_send(simulator, CMD_COOKIES, params)

    @mcp.tool()
    async def undo_manager(
        simulator: str | None = Field(default=None, description="Simulator UDID"),
        action: str = Field(default="list", description="Action: list, status, undo, redo"),
        index: int | None = Field(default=None, description="Manager index from 'list' (default: 0, the first found)"),
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
        return await resolve_and_send(simulator, CMD_UNDO, params)

    @mcp.tool()
    async def sandbox(
        simulator: str | None = Field(default=None, description="Simulator UDID"),
        action: str = Field(default="paths", description="Action: paths, list, read, write, delete, info, size"),
        path: str | None = Field(
            default=None,
            description="File or directory path. Supports shorthands: documents/, caches/, library/, tmp/, bundle/, ~/ or absolute paths",
        ),
        content: str | None = Field(default=None, description="File content to write (for write action)"),
        base64: bool = Field(default=False, description="If true, content is base64-encoded binary data (for write)"),
        recursive: bool = Field(default=False, description="List files recursively (for list action)"),
        max_length: int | None = Field(
            default=None, description="Max characters/bytes to read (default: 50000 for text, 10000 for binary)"
        ),
    ) -> str:
        """Browse, read, write, and delete files in the app's sandbox directories.
        Direct in-process FileManager access — no shell gymnastics to find simulator data paths.

        Actions:
        - paths: show container directory paths (Documents, Library, Caches, tmp, bundle) with item counts
        - list: list files/directories with size and modification date. Use path shorthands: documents/, caches/, library/, tmp/, bundle/
        - read: read file contents — auto-detects format (text, JSON with pretty-print, plist as JSON, binary as base64)
        - write: write or overwrite a file (creates parent directories). Set base64=true for binary data
        - delete: remove a file or directory (refuses app bundle writes)
        - info: file attributes — size, creation date, modification date, permissions
        - size: directory size summary per subdirectory — great for cache bloat detection

        Related tools: defaults (UserDefaults), cookies (HTTP cookies), keychain (credentials)."""
        params: dict = {"action": action}
        if path:
            params["path"] = path
        if content is not None:
            params["content"] = content
        if base64:
            params["base64"] = base64
        if recursive:
            params["recursive"] = recursive
        if max_length is not None:
            params["max_length"] = max_length
        return await resolve_and_send(simulator, CMD_SANDBOX, params)

    @mcp.tool()
    async def storage(
        simulator: str | None = Field(default=None, description="Simulator UDID"),
        action: str = Field(default="summary", description="Action: summary, coredata, clear"),
        entity: str | None = Field(
            default=None, description="Core Data entity name (for coredata detail or clear coredata)"
        ),
        type: str | None = Field(
            default=None, description="Storage type to clear: defaults, keychain, coredata (for clear action)"
        ),
        limit: int | None = Field(default=None, description="Max rows to return (for coredata, default 50)"),
    ) -> str:
        """Unified persistence inspector — view UserDefaults, Keychain, and Core Data in one place.

        Actions:
        - summary: overview of all storage layers (key counts, Core Data entities and rows)
        - coredata: list Core Data entities and row counts, or pass entity name to see rows
        - clear: reset a storage layer (pass type=defaults/keychain/coredata)

        For direct UserDefaults or Keychain access, use the dedicated `defaults` and `keychain`
        tools which have full read/write support.

        Related tools: defaults (UserDefaults read/write), keychain (credential management),
        cookies (HTTP cookies)."""
        params: dict = {"action": action}
        if entity:
            params["entity"] = entity
        if type:
            params["type"] = type
        if limit is not None:
            params["limit"] = limit
        return await resolve_and_send(simulator, CMD_STORAGE, params)

    @mcp.tool()
    async def coredata(
        simulator: str | None = Field(default=None, description="Simulator UDID"),
        action: str = Field(default="entities", description="Action: entities"),
    ) -> str:
        """Inspect the Core Data schema — entities, attributes, and relationships.

        Discovers the app's NSPersistentContainer via common singleton patterns
        (AppDelegate.persistentContainer, PersistenceController.shared, etc.) and
        returns the managed object model schema.

        Actions:
        - entities: list all entity names, their attributes, and their relationships

        Returns structured JSON:
        { "entities": [{ "name": "User", "attributes": ["id", "name"], "relationships": ["posts"] }] }

        Related tools: storage (Core Data row counts and data), heap (object discovery)."""
        return await resolve_and_send(simulator, CMD_COREDATA, {"action": action})

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
        action: str = Field(description="Action: list | dump | mirror | set | discover"),
        class_name: str | None = Field(default=None, description="ViewModel class name (for dump/mirror/set)"),
        path: str | None = Field(default=None, description="Property path (for set, e.g. 'MyVM.flag')"),
        value: str | None = Field(default=None, description="Value to set (for set action)"),
    ) -> str:
        """Check or change ViewModel @Published properties at runtime — no rebuild needed."""
        params: dict = {"action": action}
        if class_name:
            params["class"] = class_name
        if path:
            params["path"] = path
        if value is not None:
            params["value"] = try_parse_json(value)
        # Heap scan on first call can take 30+s — needs longer timeout
        return await resolve_and_send(simulator, CMD_VARS, params, timeout=45)

    @mcp.tool()
    async def defaults(
        simulator: str | None = Field(default=None, description="Simulator UDID"),
        action: str = Field(default="list", description="Action: list, get, set, delete"),
        key: str | None = Field(default=None, description="UserDefaults key (for get/set/delete)"),
        value: str | None = Field(default=None, description="Value to set (JSON: string, number, bool, array, dict)"),
        prefix: str | None = Field(default=None, description="Filter keys by prefix (for list)"),
        suite: str | None = Field(default=None, description="UserDefaults suite name (default: standard)"),
    ) -> str:
        """Read and write NSUserDefaults — the app's persistent key-value storage for debug flags, feature toggles, and configuration."""
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
        """Read or write the iOS simulator clipboard (UIPasteboard.general)."""
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
        """Inspect and modify iOS Keychain items — stored credentials, auth tokens, API secrets."""
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
        """Inspect HTTP cookies from HTTPCookieStorage.shared — session tokens, tracking IDs, consent flags."""
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
        """Inspect and control NSUndoManager — query undo/redo stack state and trigger undo/redo."""
        params: dict = {"action": action}
        if index is not None:
            params["index"] = index
        return await resolve_and_send(simulator, CMD_UNDO, params)

    @mcp.tool()
    async def sandbox(
        simulator: str | None = Field(default=None, description="Simulator UDID"),
        action: str = Field(default="paths", description="Action: paths | list | read | write | delete | info | size"),
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
        """Browse, read, write, and delete files in the app's sandbox directories."""
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
        """Unified persistence overview — view UserDefaults, Keychain, and Core Data counts in one call. Use defaults/keychain for direct read/write."""
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
        """Inspect the Core Data schema — list entities, their attributes, and relationships."""
        return await resolve_and_send(simulator, CMD_COREDATA, {"action": action})

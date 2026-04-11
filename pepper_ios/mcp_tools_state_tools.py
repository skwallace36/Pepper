"""Grouped state tools — defaults, keychain, clipboard, cookies, sandbox, coredata, undo_manager, flags as subcommands."""

from __future__ import annotations

from pydantic import Field

from .pepper_commands import (
    CMD_CLIPBOARD,
    CMD_COOKIES,
    CMD_COREDATA,
    CMD_DEFAULTS,
    CMD_FLAGS,
    CMD_KEYCHAIN,
    CMD_SANDBOX,
    CMD_UNDO,
)
from .pepper_common import require_parse_json, try_parse_json


def register_state_grouped_tools(mcp, resolve_and_send):
    """Register the state_tools grouped tool.

    Args:
        mcp: FastMCP server instance.
        resolve_and_send: async (simulator, cmd, params?, timeout?) -> str (JSON)
    """

    @mcp.tool(name="state_tools")
    async def state_tools(
        command: str = Field(
            description="Subcommand: defaults | keychain | clipboard | cookies | sandbox | coredata | undo_manager | flags"
        ),
        simulator: str | None = Field(default=None, description="Simulator UDID"),
        # shared
        action: str | None = Field(default=None, description="Action for the subcommand (e.g. read/write/list/get/set/clear)"),
        key: str | None = Field(default=None, description="[defaults/flags] Key name"),
        value: str | None = Field(default=None, description="[defaults/keychain/flags/clipboard] Value to set"),
        # defaults params
        prefix: str | None = Field(default=None, description="[defaults] Filter keys by prefix"),
        suite: str | None = Field(default=None, description="[defaults] UserDefaults suite name (default: standard)"),
        # keychain params
        service: str | None = Field(default=None, description="[keychain] Service name filter"),
        account: str | None = Field(default=None, description="[keychain] Account name filter"),
        # cookies params
        domain: str | None = Field(default=None, description="[cookies] Domain filter"),
        name: str | None = Field(default=None, description="[cookies] Cookie name filter"),
        # sandbox params
        path: str | None = Field(default=None, description="[sandbox] File/directory path"),
        content: str | None = Field(default=None, description="[sandbox] File content to write"),
        base64: bool = Field(default=False, description="[sandbox] Content is base64 encoded"),
        recursive: bool = Field(default=False, description="[sandbox] List directory recursively"),
        max_length: int | None = Field(default=None, description="[sandbox] Max bytes to read"),
        # undo params
        index: int | None = Field(default=None, description="[undo_manager] Undo/redo to specific index"),
    ) -> str:
        """App state inspection and mutation tools. Subcommands:
        - defaults: Read/write NSUserDefaults
        - keychain: Inspect/modify iOS Keychain items
        - clipboard: Read/write simulator clipboard
        - cookies: Inspect HTTP cookies
        - sandbox: Browse, read, write, delete files in app sandbox
        - coredata: Inspect Core Data schema
        - undo_manager: Inspect/control NSUndoManager
        - flags: Override feature flags by intercepting network responses"""

        if command == "defaults":
            params: dict = {"action": action or "list"}
            if key:
                params["key"] = key
            if prefix:
                params["prefix"] = prefix
            if suite:
                params["suite"] = suite
            if value is not None:
                params["value"] = try_parse_json(value)
            return await resolve_and_send(simulator, CMD_DEFAULTS, params)

        elif command == "keychain":
            params = {"action": action or "list"}
            if service:
                params["service"] = service
            if account:
                params["account"] = account
            if value is not None:
                params["value"] = value
            return await resolve_and_send(simulator, CMD_KEYCHAIN, params)

        elif command == "clipboard":
            params = {"action": action or "read"}
            if value is not None:
                params["value"] = value
            return await resolve_and_send(simulator, CMD_CLIPBOARD, params)

        elif command == "cookies":
            params = {"action": action or "list"}
            if domain:
                params["domain"] = domain
            if name:
                params["name"] = name
            return await resolve_and_send(simulator, CMD_COOKIES, params)

        elif command == "sandbox":
            params = {"action": action or "paths"}
            if path:
                params["path"] = path
            if content is not None:
                params["content"] = content
            if base64:
                params["base64"] = True
            if recursive:
                params["recursive"] = True
            if max_length is not None:
                params["max_length"] = max_length
            return await resolve_and_send(simulator, CMD_SANDBOX, params)

        elif command == "coredata":
            return await resolve_and_send(simulator, CMD_COREDATA, {"action": action or "schema"})

        elif command == "undo_manager":
            params = {"action": action or "status"}
            if index is not None:
                params["index"] = index
            return await resolve_and_send(simulator, CMD_UNDO, params)

        elif command == "flags":
            params = {"action": action or "list"}
            if key:
                params["key"] = key
            if value is not None:
                params["value"] = try_parse_json(value)
            return await resolve_and_send(simulator, CMD_FLAGS, params)

        return f"Unknown command '{command}'. Use: defaults, keychain, clipboard, cookies, sandbox, coredata, undo_manager, flags"

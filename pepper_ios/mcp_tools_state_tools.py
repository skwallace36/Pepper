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
from .pepper_common import try_parse_json


def register_state_grouped_tools(mcp, resolve_and_send):
    """Register the state_tools grouped tool."""

    @mcp.tool(name="state_tools")
    async def state_tools(
        command: str = Field(description="Subcommand: defaults | keychain | clipboard | cookies | sandbox | coredata | undo_manager | flags"),
        simulator: str | None = Field(default=None, description="Simulator UDID"),
        action: str | None = Field(default=None, description="Action for the subcommand (e.g. read/write/list/get/set/clear)"),
        key: str | None = Field(default=None, description="Key name (defaults/flags)"),
        value: str | None = Field(default=None, description="Value to set (defaults/keychain/flags/clipboard)"),
        prefix: str | None = Field(default=None, description="Filter keys by prefix (defaults)"),
        suite: str | None = Field(default=None, description="UserDefaults suite name (defaults)"),
        service: str | None = Field(default=None, description="Service name filter (keychain)"),
        account: str | None = Field(default=None, description="Account name filter (keychain)"),
        domain: str | None = Field(default=None, description="Domain filter (cookies)"),
        name: str | None = Field(default=None, description="Cookie name filter (cookies)"),
        path: str | None = Field(default=None, description="File/directory path (sandbox)"),
        content: str | None = Field(default=None, description="File content to write (sandbox)"),
        base64: bool = Field(default=False, description="Content is base64 encoded (sandbox)"),
        recursive: bool = Field(default=False, description="List directory recursively (sandbox)"),
        max_length: int | None = Field(default=None, description="Max bytes to read (sandbox)"),
        index: int | None = Field(default=None, description="Undo/redo to specific index (undo_manager)"),
    ) -> str:
        """App state inspection and mutation.

Subcommands:
- defaults: Read/write NSUserDefaults. Actions: list, read, write, delete
- keychain: Inspect/modify Keychain items. Actions: list, read, write, delete
- clipboard: Read/write simulator clipboard. Actions: read, write
- cookies: Inspect HTTP cookies. Actions: list, delete, clear
- sandbox: Browse/read/write/delete app sandbox files. Actions: paths, list, read, write, delete, info, size
- coredata: Inspect Core Data schema. Actions: schema
- undo_manager: Inspect/control NSUndoManager. Actions: status, undo, redo
- flags: Override feature flags via network interception. Actions: list, get, set, clear"""

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

        return f"Error: unknown command '{command}'. Use: defaults, keychain, clipboard, cookies, sandbox, coredata, undo_manager, flags"

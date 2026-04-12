"""Grouped system tools — push, orientation, locale, appearance, dynamic_type, hook, frameworks, usage as subcommands."""

from __future__ import annotations

from pydantic import Field

from .pepper_commands import (
    CMD_APPEARANCE,
    CMD_DYNAMIC_TYPE,
    CMD_HOOK,
    CMD_LOCALE,
    CMD_ORIENTATION,
    CMD_PUSH,
)
from .pepper_common import require_parse_json


def register_sys_grouped_tools(mcp, resolve_and_send):
    """Register the sys_tools grouped tool."""

    @mcp.tool(name="sys_tools")
    async def sys_tools(
        command: str = Field(description="Subcommand: push | orientation | locale | appearance | dynamic_type | hook | frameworks | usage"),
        simulator: str | None = Field(default=None, description="Simulator UDID"),
        action: str | None = Field(default=None, description="Action for the subcommand"),
        title: str | None = Field(default=None, description="Notification title (push)"),
        body: str | None = Field(default=None, description="Notification body text (push)"),
        data: str | None = Field(default=None, description="JSON userInfo payload (push)"),
        value: str | None = Field(default=None, description="Target value (orientation: portrait/landscape_left/landscape_right)"),
        language: str | None = Field(default=None, description="Language code, e.g. 'es' (locale)"),
        region: str | None = Field(default=None, description="Region code, e.g. 'JP' (locale)"),
        key: str | None = Field(default=None, description="Localization key to look up (locale)"),
        mode: str | None = Field(default=None, description="Appearance mode: dark, light, system (appearance)"),
        size: str | None = Field(default=None, description="Content size category, e.g. 'large' (dynamic_type)"),
        class_name: str | None = Field(default=None, description="ObjC class name (hook)"),
        method: str | None = Field(default=None, description="ObjC method name (hook)"),
        class_method: bool = Field(default=False, description="Hook class method (+) instead of instance (-) (hook)"),
        hook_id: str | None = Field(default=None, description="Hook ID for remove/log/clear (hook)"),
        limit: int | None = Field(default=None, description="Max log entries to return (hook)"),
        name: str | None = Field(default=None, description="Image name substring to match (frameworks)"),
        filter_text: str | None = Field(default=None, description="Filter images by name (frameworks)"),
        days: int | None = Field(default=None, description="Look back this many days, default 30 (usage)"),
    ) -> str:
        """System and device tools.

Subcommands:
- push: Simulate push notifications. Actions: deliver, pending, clear
- orientation: Get/set device orientation
- locale: Override app locale at runtime. Actions: current, set, reset, lookup, languages
- appearance: Toggle light/dark mode
- dynamic_type: Override font size for accessibility testing. Actions: current, set, reset, sizes
- hook: Hook ObjC methods to log invocations. Actions: install, remove, remove_all, list, log, clear
- frameworks: List loaded dylibs and frameworks. Actions: list, detail
- usage: Show tool usage statistics from ~/.pepper/tool_usage.jsonl"""

        if command == "push":
            params: dict = {}
            if action:
                params["action"] = action
            if title:
                params["title"] = title
            if body:
                params["body"] = body
            if data:
                try:
                    params["data"] = require_parse_json(data, "data")
                except ValueError as e:
                    return f"Error: {e}"
            return await resolve_and_send(simulator, CMD_PUSH, params)

        elif command == "orientation":
            params = {}
            if value:
                params["value"] = value
            return await resolve_and_send(simulator, CMD_ORIENTATION, params)

        elif command == "locale":
            params = {}
            if action:
                params["action"] = action
            if language:
                params["language"] = language
            if region:
                params["region"] = region
            if key:
                params["key"] = key
            return await resolve_and_send(simulator, CMD_LOCALE, params)

        elif command == "appearance":
            params = {}
            if mode:
                params["mode"] = mode
            return await resolve_and_send(simulator, CMD_APPEARANCE, params)

        elif command == "dynamic_type":
            params = {}
            if action:
                params["action"] = action
            if size:
                params["size"] = size
            return await resolve_and_send(simulator, CMD_DYNAMIC_TYPE, params)

        elif command == "hook":
            params = {"action": action or "list"}
            if class_name:
                params["class"] = class_name
            if method:
                params["method"] = method
            if class_method:
                params["class_method"] = True
            if hook_id:
                params["id"] = hook_id
            if limit is not None:
                params["limit"] = limit
            return await resolve_and_send(simulator, CMD_HOOK, params)

        elif command == "frameworks":
            params = {"action": action or "list"}
            if name is not None:
                params["name"] = name
            if filter_text is not None:
                params["filter"] = filter_text
            return await resolve_and_send(simulator, "frameworks", params)

        elif command == "usage":
            from .pepper_usage import get_usage_summary
            import json
            summary = get_usage_summary(days=days or 30)
            return json.dumps(summary, indent=2)

        return f"Error: unknown command '{command}'. Use: push, orientation, locale, appearance, dynamic_type, hook, frameworks, usage"

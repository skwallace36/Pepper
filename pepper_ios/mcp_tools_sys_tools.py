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
    """Register the sys_tools grouped tool.

    Args:
        mcp: FastMCP server instance.
        resolve_and_send: async (simulator, cmd, params?, timeout?) -> str (JSON)
    """

    @mcp.tool(name="sys_tools")
    async def sys_tools(
        command: str = Field(
            description="Subcommand: push | orientation | locale | appearance | dynamic_type | hook | frameworks | usage"
        ),
        simulator: str | None = Field(default=None, description="Simulator UDID"),
        # push params
        action: str | None = Field(default=None, description="[push] deliver/pending/clear; [locale] current/set/reset/lookup/languages; [dynamic_type] current/set/reset/sizes; [hook] install/remove/remove_all/list/log/clear; [frameworks] list/detail"),
        title: str | None = Field(default=None, description="[push] Notification title"),
        body: str | None = Field(default=None, description="[push] Notification body text"),
        data: str | None = Field(default=None, description="[push] JSON userInfo payload"),
        # orientation params
        value: str | None = Field(default=None, description="[orientation] portrait/landscape_left/landscape_right/portrait_upside_down"),
        # locale params
        language: str | None = Field(default=None, description="[locale] Language code (e.g. 'es', 'ja')"),
        region: str | None = Field(default=None, description="[locale] Region code (e.g. 'JP', 'US')"),
        key: str | None = Field(default=None, description="[locale] Localization key to look up"),
        # appearance params
        mode: str | None = Field(default=None, description="[appearance] dark/light/system"),
        # dynamic_type params
        size: str | None = Field(default=None, description="[dynamic_type] Content size category (e.g. 'extraSmall', 'large', 'accessibilityExtraExtraExtraLarge')"),
        # hook params
        class_name: str | None = Field(default=None, description="[hook] ObjC class name"),
        method: str | None = Field(default=None, description="[hook] ObjC method name"),
        class_method: bool = Field(default=False, description="[hook] Hook class method (+) instead of instance (-)"),
        hook_id: str | None = Field(default=None, description="[hook] Hook ID for remove/log/clear"),
        limit: int | None = Field(default=None, description="[hook] Max log entries to return"),
        # frameworks params
        name: str | None = Field(default=None, description="[frameworks] Image name substring to match"),
        filter_text: str | None = Field(default=None, description="[frameworks] Filter images by name"),
        # usage params
        days: int | None = Field(default=None, description="[usage] Look back this many days (default: 30)"),
    ) -> str:
        """System and device tools. Subcommands:
        - push: Simulate push notifications with title, body, and deeplink data
        - orientation: Get/set device orientation
        - locale: Override app locale at runtime
        - appearance: Toggle light/dark mode
        - dynamic_type: Override Dynamic Type (font size) for accessibility testing
        - hook: Hook ObjC methods at runtime to log invocations
        - frameworks: List loaded dylibs and frameworks
        - usage: Show tool usage statistics"""

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

        return f"Unknown command '{command}'. Use: push, orientation, locale, appearance, dynamic_type, hook, frameworks, usage"

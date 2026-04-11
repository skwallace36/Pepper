"""Grouped app debug tool — layers, crash_log, constraints, responder_chain, target_actions, highlight, lifecycle, notifications, webview as subcommands."""

from __future__ import annotations

import json
import os
import time

from pydantic import Field

from .mcp_crash import parse_crash_report
from .pepper_commands import (
    CMD_CONSTRAINTS,
    CMD_HIGHLIGHT,
    CMD_LAYERS,
    CMD_LIFECYCLE,
    CMD_NOTIFICATIONS,
    CMD_RESPONDER_CHAIN,
)
from .pepper_common import get_config


def register_app_debug_tools(mcp, resolve_and_send):
    """Register the app_debug grouped tool."""

    @mcp.tool(name="app_debug")
    async def app_debug(
        command: str = Field(description="Subcommand: layers | crash_log | constraints | responder_chain | target_actions | highlight | lifecycle | notifications | webview"),
        simulator: str | None = Field(default=None, description="Simulator UDID"),
        point: str | None = Field(default=None, description="Screen coordinates 'x,y' (layers/responder_chain)"),
        depth: int | None = Field(default=None, description="Max depth (layers/constraints)"),
        last_n: int | None = Field(default=None, description="Number of recent reports, max 5 (crash_log)"),
        seconds: int | None = Field(default=None, description="Look back this many seconds, default 300 (crash_log)"),
        element: str | None = Field(default=None, description="Accessibility ID (constraints/responder_chain/target_actions/highlight)"),
        ambiguous_only: bool = Field(default=False, description="Only views with ambiguous layout (constraints)"),
        mode: str | None = Field(default=None, description="constraints: constraints, spacing, audit"),
        text: str | None = Field(default=None, description="Text label (responder_chain/target_actions/highlight)"),
        control_class: str | None = Field(default=None, description="Filter by control class, e.g. 'UIButton' (target_actions)"),
        frame: str | None = Field(default=None, description="Frame as 'x,y,width,height' (highlight)"),
        color: str | None = Field(default=None, description="Border color: red, green, blue, yellow, etc. (highlight)"),
        label: str | None = Field(default=None, description="Overlay label text (highlight)"),
        duration: float | None = Field(default=None, description="Auto-clear after N seconds (highlight)"),
        clear: bool = Field(default=False, description="Clear all highlights (highlight)"),
        action: str | None = Field(default=None, description="lifecycle: background/foreground/memory_warning. notifications: start/stop/list/counts/post/events/status/clear. webview: url/evaluate/dom"),
        name: str | None = Field(default=None, description="Notification name to post (notifications)"),
        filter_text: str | None = Field(default=None, description="Filter by name/class pattern (notifications)"),
        user_info: dict | str | None = Field(default=None, description="userInfo dict for post (notifications)"),
        limit: int | None = Field(default=None, description="Max results (notifications/webview dom)"),
        script: str | None = Field(default=None, description="JavaScript to execute (webview evaluate)"),
        selector: str | None = Field(default=None, description="CSS selector for DOM query (webview dom)"),
        index: int | None = Field(default=None, description="WKWebView index when multiple present (webview)"),
    ) -> str:
        """Deep debugging tools.

Subcommands:
- layers: Inspect CALayer tree at a screen point
- crash_log: Fetch and parse recent crash reports
- constraints: Dump AutoLayout constraints with ambiguity detection
- responder_chain: Dump gesture recognizers and responder chain
- target_actions: List UIControl target-action pairs
- highlight: Draw colored border around element for visual debugging
- lifecycle: Trigger app lifecycle events
- notifications: Track NSNotificationCenter observers and post notifications
- webview: Inspect WKWebView — get URLs, execute JavaScript, query DOM"""

        if command == "layers":
            if not point:
                return "Error: point required, e.g. '200,400'"
            params: dict = {"point": point}
            if depth is not None:
                params["depth"] = depth
            return await resolve_and_send(simulator, CMD_LAYERS, params)

        elif command == "crash_log":
            cfg = get_config()
            bundle_id = cfg.get("bundle_id", "")
            app_name_hint = bundle_id.rsplit(".", 1)[-1].lower() if bundle_id else ""
            reports_dir = os.path.expanduser("~/Library/Logs/DiagnosticReports")

            if not os.path.isdir(reports_dir):
                return "No DiagnosticReports directory found."

            cutoff = time.time() - (seconds or 300)
            n = min(last_n or 1, 5)
            candidates = []
            all_app_reports = []
            try:
                for entry in os.scandir(reports_dir):
                    if entry.name.endswith(".ips"):
                        try:
                            mtime = entry.stat().st_mtime
                            if mtime >= cutoff:
                                candidates.append((mtime, entry.path))
                            if app_name_hint:
                                fname_lower = entry.name.lower()
                                if fname_lower.startswith(app_name_hint + "-") or fname_lower.startswith(app_name_hint + "_"):
                                    all_app_reports.append((mtime, entry.path))
                        except OSError:
                            pass
            except OSError:
                return "Failed to read DiagnosticReports directory."

            if not candidates:
                throttle_warning = ""
                if len(all_app_reports) >= 25:
                    throttle_warning = (
                        f"\n\nWARNING: Found {len(all_app_reports)} total crash reports for "
                        f"'{app_name_hint}'. macOS throttles after ~25. Delete old reports:\n"
                        f"  rm ~/Library/Logs/DiagnosticReports/{app_name_hint.capitalize()}-*.ips"
                    )
                return f"No crash reports found in the last {seconds or 300}s.{throttle_warning}"

            candidates.sort(reverse=True)

            def _matches_app(content: str, filepath: str) -> bool:
                if not bundle_id:
                    return True
                if bundle_id in content:
                    return True
                if app_name_hint:
                    fname_lower = os.path.basename(filepath).lower()
                    if fname_lower.startswith(app_name_hint + "-") or fname_lower.startswith(app_name_hint + "_"):
                        return True
                    try:
                        header_line = content.split("\n", 1)[0]
                        header = json.loads(header_line)
                        if header.get("app_name", "").lower() == app_name_hint:
                            return True
                    except (json.JSONDecodeError, IndexError):
                        pass
                return False

            results = []
            for _, path in candidates:
                if len(results) >= n:
                    break
                try:
                    with open(path) as f:
                        content = f.read()
                    if not _matches_app(content, path):
                        continue
                    parsed = parse_crash_report(path, content)
                    if parsed:
                        results.append(parsed)
                except OSError:
                    continue

            if not results:
                other_names = set()
                for _, path in candidates[:10]:
                    other_names.add(os.path.basename(path).split("-")[0])
                others_str = ", ".join(sorted(other_names)) if other_names else "none"
                throttle_warning = ""
                if len(all_app_reports) >= 25:
                    throttle_warning = (
                        f"\nWARNING: macOS likely throttled — {len(all_app_reports)} reports for "
                        f"'{app_name_hint}'. Delete old reports:\n"
                        f"  rm ~/Library/Logs/DiagnosticReports/{app_name_hint.capitalize()}-*.ips"
                    )
                return (
                    f"No crash reports matching {bundle_id} in the last {seconds or 300}s. "
                    f"Found {len(candidates)} .ips files (from: {others_str}).{throttle_warning}"
                )
            return "\n".join(results)

        elif command == "constraints":
            params = {}
            if element:
                params["element"] = element
            if ambiguous_only:
                params["ambiguous_only"] = True
            if depth is not None:
                params["depth"] = depth
            if mode:
                params["mode"] = mode
            return await resolve_and_send(simulator, CMD_CONSTRAINTS, params)

        elif command == "responder_chain":
            params = {}
            if point:
                parts = point.split(",")
                if len(parts) == 2:
                    params["point"] = {"x": float(parts[0]), "y": float(parts[1])}
            if element:
                params["element"] = element
            if text:
                params["text"] = text
            return await resolve_and_send(simulator, CMD_RESPONDER_CHAIN, params)

        elif command == "target_actions":
            params = {}
            if element:
                params["element"] = element
            if text:
                params["text"] = text
            if control_class:
                params["class"] = control_class
            return await resolve_and_send(simulator, "target_actions", params)

        elif command == "highlight":
            params = {}
            if clear:
                params["clear"] = True
            elif text:
                params["text"] = text
            elif element:
                params["element"] = element
            elif frame:
                parts = frame.split(",")
                if len(parts) == 4:
                    params["frame"] = {"x": float(parts[0]), "y": float(parts[1]), "width": float(parts[2]), "height": float(parts[3])}
            if color:
                params["color"] = color
            if label:
                params["label"] = label
            if duration is not None:
                params["duration"] = duration
            return await resolve_and_send(simulator, CMD_HIGHLIGHT, params)

        elif command == "lifecycle":
            if not action:
                return "Error: action required. Use: background, foreground, memory_warning"
            return await resolve_and_send(simulator, CMD_LIFECYCLE, {"action": action})

        elif command == "notifications":
            if not action:
                return "Error: action required. Use: start, stop, list, counts, post, events, status, clear"
            params = {"action": action}
            if name:
                params["name"] = name
            if filter_text:
                params["filter"] = filter_text
            if user_info is not None:
                if isinstance(user_info, str):
                    try:
                        params["user_info"] = json.loads(user_info)
                    except json.JSONDecodeError:
                        return "Error: user_info must be valid JSON"
                else:
                    params["user_info"] = user_info
            if limit is not None:
                params["limit"] = limit
            return await resolve_and_send(simulator, CMD_NOTIFICATIONS, params)

        elif command == "webview":
            params = {"action": action or "url"}
            if script is not None:
                params["script"] = script
            if selector is not None:
                params["selector"] = selector
            if index is not None:
                params["index"] = index
            if limit is not None:
                params["limit"] = limit
            return await resolve_and_send(simulator, "webview", params, timeout=15)

        return f"Error: unknown command '{command}'. Use: layers, crash_log, constraints, responder_chain, target_actions, highlight, lifecycle, notifications, webview"

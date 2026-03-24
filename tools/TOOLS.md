# tools/

External tooling that connects to Pepper's WebSocket server from outside the app process.

## MCP Integration

Pepper exposes its runtime capabilities as [MCP (Model Context Protocol)](https://modelcontextprotocol.io) tools. This is the primary integration point — AI agents like Claude call MCP tools directly, and the MCP server translates them into WebSocket commands sent to the dylib running inside the app.

### End-to-end flow

```
Claude / AI agent
  ↓  MCP tool call (e.g. "tap", "look", "scroll")
pepper-mcp (Python, stdio transport)
  ↓  WebSocket JSON command
Pepper dylib (inside simulator app process)
  ↓  UIKit / accessibility / HID APIs
iOS simulator app
```

Each MCP tool maps to a Pepper command. The MCP server handles connection management, port discovery, crash detection, and response formatting. Tool definitions are split across focused modules (`mcp_tools_nav.py`, `mcp_tools_state.py`, etc.) so each file stays small and single-purpose.

### What this enables

With Pepper injected, an AI agent can:

- **See the screen** — `look` returns a structured map of every visible element (labels, types, frames, interactability) without screenshots.
- **Interact like a user** — `tap`, `scroll`, `swipe`, `input_text`, and `gesture` synthesize real HID touch events. Both UIKit and SwiftUI respond identically because Pepper uses the same IOHIDEvent pipeline the system uses.
- **Navigate** — `navigate` triggers deep links, `back` and `dismiss` manage the navigation stack, `dialog` handles alerts and action sheets.
- **Inspect state** — `vars_inspect` reads arbitrary properties, `heap` queries live objects, `defaults` / `keychain` / `cookies` / `clipboard` access storage layers.
- **Debug** — `console` shows logs, `network` shows HTTP traffic, `crash_log` fetches crash reports, `layers` visualizes the view hierarchy, `timeline` replays events.
- **Control the simulator** — `orientation`, `locale`, `push` (simulated push notifications), `status` (status bar overrides), `simulator` (simctl operations).
- **Build and deploy** — `build` compiles the app, `deploy` installs with Pepper injected, `iterate` does build+deploy+verify in one step.

No source access required. The agent operates on any iOS simulator app as-is.

## Top-level tools

### `pepper-mcp` (Python)
MCP server that bridges Claude Code to Pepper. Wraps WebSocket commands as MCP tools. Configured via `.mcp.json` in the project root.

This is the primary interface — Claude calls MCP tools directly instead of shell commands. Tool definitions and handler logic are split across `mcp_tools_*.py` modules (see below).

### `pepper-ctl` (Python)
CLI for sending WebSocket commands. Used for manual testing, scripting, and as a fallback when MCP isn't available.

```bash
python3 tools/pepper-ctl look                    # compact screen summary
python3 tools/pepper-ctl tap --text "Settings"   # tap by label
python3 tools/pepper-ctl --json look             # full raw JSON
python3 tools/pepper-ctl --port 8813 ping        # specific port
python3 tools/pepper-ctl raw '{"cmd":"heap","params":{"action":"classes","pattern":"Manager"}}'
```

Multi-sim: `--simulator <UDID>` auto-discovers port from `/tmp/pepper-ports/`.

### `pepper-stream` (Python)
Real-time event stream viewer. Connects to Pepper's WebSocket and prints events as they arrive.

### `pepper-context` (Python)
Source code context lookup. Helps agents find relevant source for a given command or concept.

### `test-client.py` (Python)
Interactive REPL for exploring Pepper commands. Good for experimentation.

## Shared library — `pepper_common`, `pepper_format`, `pepper_websocket`

Shared modules imported by `pepper-mcp`, `pepper-ctl`, `pepper-stream`, and `test-client.py`. One concern per module.

### `pepper_common.py`
Constants and config helpers: `PEPPER_DIR`, `PORT_DIR`, `load_env()`, `get_config()`, `require_tool()`, `discover_port()`, `discover_simulator()`, `list_simulators()`, `try_parse_json()`, `require_parse_json()`. Port discovery includes liveness checks (TCP connect to confirm the server is actually listening).

### `pepper_format.py`
Output formatting: `format_look()` for rendering `introspect map` responses as human-readable text. Optional ANSI color support controlled by `USE_COLOR` flag.

### `pepper_websocket.py`
WebSocket communication: `make_command()`, `recv_response()`, `send_command()` with event filtering, crash detection (`CrashError`), and command ID matching.

### `pepper_sessions.py`
File-based session management for multi-agent simulator coordination. Each MCP server process claims a simulator exclusively via session files in `/tmp/pepper-sessions/`. Handles liveness detection (PID + heartbeat), stale cleanup, and reuse-first simulator provisioning with a configurable cap (`PEPPER_MAX_SIMS`, default 3). Imported by `pepper-mcp` and `pepper-ctl`.

## MCP modules — `mcp_*.py`

Extracted from `pepper-mcp` into focused modules. Each is imported by `pepper-mcp`; none runs standalone.

### Tool definitions

| Module | Tools |
|--------|-------|
| `mcp_tools_nav.py` | look, tap, scroll, input_text, navigate, back, dismiss, swipe, screen, scroll_to, dismiss_keyboard |
| `mcp_tools_state.py` | vars_inspect, defaults, clipboard, keychain, cookies |
| `mcp_tools_debug.py` | layers, console, network, timeline, crash_log, animations, lifecycle, heap |
| `mcp_tools_system.py` | push, status, highlight, orientation, locale, gesture, hook, find, flags, dialog, toggle, read_element, tree |
| `mcp_tools_record.py` | record (start/stop simulator recording, mp4/gif output) |
| `mcp_tools_sim.py` | raw (send any command), simulator (simctl operations) |

### Support modules

| Module | Purpose |
|--------|---------|
| `mcp_build.py` | Simulator resolution, `xcodebuild` invocation, app deployment with dylib injection, device build/deploy, `iterate()` |
| `mcp_crash.py` | Crash log parsing (`parse_crash_report()`) and fetching (`fetch_crash_info()`) |

## Build & deploy scripts

### `build-dylib.sh` (Bash)
Compiles `dylib/` into `build/Pepper.framework/Pepper`. Called by `make build`.

### `inject-xcode-scheme.py` (Python)
Injects Pepper's DYLD_INSERT_LIBRARIES into an Xcode scheme for automatic injection during Xcode builds.

### `check-sim-available.py` (Python)
Pre-deploy check — verifies the target simulator is available and atomically pre-claims it via the session system before deployment starts.

### `upload-screenshot` (Python)
Uploads screenshots to GitHub PRs.

## Dependencies

Python packages: `websockets` (required), `mcp` (for pepper-mcp). See `requirements.txt` at repo root.

```bash
pip3 install -r requirements.txt
```

---

**Routing:** Bugs → GitHub Issues (`gh issue list --label bug`) | Work items → `../ROADMAP.md` | Test coverage → `../test-app/COVERAGE.md` | Research → `../docs/internal/RESEARCH.md`

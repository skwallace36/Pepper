# tools/

External tooling that connects to Pepper's WebSocket server from outside the app process.

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
Constants and config helpers: `PEPPER_DIR`, `PORT_DIR`, `load_env()`, `get_config()`, `require_tool()`, `discover_port()`, `discover_simulator()`, `list_simulators()`. Port discovery includes liveness checks (TCP connect to confirm the server is actually listening).

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
| `mcp_screenshot.py` | Screenshot capture via `simctl` + `sips` pipeline, standard and high quality modes |
| `mcp_telemetry.py` | Pre/post action telemetry snapshots (`snapshot_counts()`), delta reporting (`gather_telemetry()`), act-and-look workflow (`act_and_look()`) |

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

**Routing:** Bugs → `../BUGS.md` | Work items → `../ROADMAP.md` | Test coverage → `../test-app/COVERAGE.md` | Research → `../docs/RESEARCH.md`

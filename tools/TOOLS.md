# tools/

External tooling that connects to Pepper's WebSocket server from outside the app process.

## Tools

### `pepper-mcp` (Python)
MCP server that bridges Claude Code to Pepper. Wraps WebSocket commands as MCP tools. Configured via `.mcp.json` in the project root.

This is the primary interface — Claude calls MCP tools directly instead of shell commands.

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

### `pepper_sessions.py` (Python)
File-based session management for multi-agent simulator coordination. Each MCP server process claims a simulator exclusively via session files in `/tmp/pepper-sessions/`. Handles liveness detection (PID + heartbeat), stale cleanup, and reuse-first simulator provisioning with a configurable cap (`PEPPER_MAX_SIMS`, default 3). Imported by `pepper-mcp` and `pepper-ctl`.

### `pepper-stream` (Python)
Real-time event stream viewer. Connects to Pepper's WebSocket and prints events as they arrive.

### `pepper-context` (Python)
Source code context lookup. Helps agents find relevant source for a given command or concept.

### `test-client.py` (Python)
Interactive REPL for exploring Pepper commands. Good for experimentation.

### `build-dylib.sh` (Bash)
Compiles `dylib/` into `build/Pepper.framework/Pepper`. Called by `make build`.

### `upload-screenshot` (Python)
Uploads screenshots to GitHub PRs.

### `inject-xcode-scheme.py` (Python)
Injects Pepper's DYLD_INSERT_LIBRARIES into an Xcode scheme for automatic injection during Xcode builds.

## Dependencies

Python packages: `websockets` (required), `mcp` (for pepper-mcp). See `requirements.txt` at repo root.

```bash
pip3 install -r requirements.txt
```

---

**Routing:** Bugs → `../BUGS.md` | Work items → `../ROADMAP.md` | Test coverage → `../test-app/COVERAGE.md` | Research → `../docs/RESEARCH.md`

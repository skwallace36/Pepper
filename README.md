# Pepper

Runtime control for iOS simulator apps. Pepper is a dylib injected into any app at launch — it gives you full introspection and interaction without screenshots, source access, or accessibility setup.

See every element, tap anything, inspect view state, monitor network traffic, explore the heap — all through a WebSocket control plane.

## How it works

Pepper uses `DYLD_INSERT_LIBRARIES` to inject a framework into an iOS simulator app at launch. The framework starts a WebSocket server inside the app process, exposing 40+ commands for observing and controlling the UI.

It works with both UIKit and SwiftUI apps. No source modifications needed.

## Quick start

```bash
# 1. Set up (checks prereqs, installs deps, sets up hooks)
make setup

# 2. Configure your target app in .env
echo 'APP_BUNDLE_ID=com.example.myapp' > .env

# 3. Deploy (build + launch with injection)
make deploy

# 4. Verify it's running
make ping
```

## Usage

### With Claude Code (MCP)

Pepper ships with an MCP server that exposes tools directly to Claude Code. With the included `.mcp.json`, Claude can:

- **`look`** — see everything on screen: interactive elements, text, tap commands
- **`tap`** / **`scroll`** — interact with the app
- **`heap`** — discover live objects, view controllers, singletons
- **`vars_inspect`** — read and write ViewModel properties
- **`network`** — monitor HTTP traffic
- **`console`** — capture app logs
- And [30+ more commands](docs/COMMANDS.md)

### With the CLI

```bash
P="python3 tools/pepper-ctl"

$P look                          # what's on screen
$P tap --text "Sign In"          # tap by label
$P scroll --direction down       # scroll
$P heap --action classes          # list live classes
$P --json look                   # full JSON output
```

### Raw WebSocket

Connect to `ws://localhost:<port>` and send JSON:

```json
{"cmd": "look"}
{"cmd": "tap", "params": {"text": "Continue"}}
{"cmd": "heap", "params": {"action": "classes", "pattern": "Manager"}}
```

## Project structure

```
├── dylib/          # Swift source for the injected framework
├── tools/          # MCP server, CLI (pepper-ctl), utilities
├── test-app/       # SwiftUI/UIKit test app for integration testing
├── scripts/        # Build and CI scripts
├── docs/           # Command reference and design docs
└── Makefile        # Build, deploy, and management targets
```

## Requirements

- macOS with Xcode and iOS Simulator
- Python 3 (for MCP server and CLI tools)
- A booted iOS simulator

## License

Private — not yet open source.

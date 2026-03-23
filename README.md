# Pepper

**MCP server for iOS engineering**

Pepper injects into any iOS Simulator app at runtime and gives your AI full access — see every element on screen, tap buttons, inspect state, intercept network traffic, and more. No SDK. No source changes. Just plug in and go.

<!-- TODO: 30-second demo GIF -->

## Setup

Add to your MCP client config (Claude Desktop, Claude Code, Cursor, etc.):

```json
{
  "mcpServers": {
    "pepper": {
      "command": "/path/to/pepper/.venv/bin/python3",
      "args": ["/path/to/pepper/tools/pepper-mcp"]
    }
  }
}
```

Then ask your agent to `look` at your app.

## Tools

50+ tools for observing, interacting with, and debugging iOS apps:

### Observe

| Tool | Description |
|------|-------------|
| `look` | See every element on screen — labels, buttons, state, frames |
| `screen` | Current screen or route name |
| `find` | Find elements matching a query |
| `tree` | Full view hierarchy |
| `layers` | Rendering layers and compositing |
| `highlight` | Visually highlight elements in the simulator |

### Interact

| Tool | Description |
|------|-------------|
| `tap` | Tap any element by label, ID, or coordinates |
| `scroll` | Scroll in any direction |
| `scroll_to` | Scroll until an element is visible |
| `swipe` | Swipe gestures |
| `gesture` | Custom multi-touch gestures |
| `input_text` | Type into text fields |
| `toggle` | Toggle switches |
| `navigate` | Deep link navigation |
| `back` | Go back |
| `dismiss` | Dismiss sheets and modals |
| `dialog` | Handle system permission dialogs |

### Debug

| Tool | Description |
|------|-------------|
| `vars_inspect` | Inspect and mutate any property at runtime |
| `heap` | Snapshot the object graph |
| `console` | Capture app logs (print, NSLog, os_log) |
| `network` | Intercept and inspect HTTP traffic |
| `crash_log` | Read crash logs |
| `timeline` | Performance event timeline |
| `animations` | Debug animations |
| `lifecycle` | View controller lifecycle events |

### App State

| Tool | Description |
|------|-------------|
| `defaults` | Read/write UserDefaults |
| `clipboard` | Read/write pasteboard |
| `keychain` | Inspect keychain items |
| `cookies` | HTTP cookies |
| `locale` | Change app locale at runtime |
| `flags` | Override feature flags via network interception |
| `push` | Send simulated push notifications |
| `orientation` | Change device orientation |

### Automation

| Tool | Description |
|------|-------------|
| `wait_for` | Wait for an element or condition |
| `wait_idle` | Wait for the app to settle |
| `record` | Screen recording |
| `deploy` | Build, inject, and launch in one step |
| `build` | Build the app |
| `iterate` | Edit code, rebuild, and verify in a loop |

## How It Works

Pepper is a dynamic library injected into the simulator process via `DYLD_INSERT_LIBRARIES`. It starts a WebSocket server *inside* the app — giving it direct access to the view hierarchy, runtime state, network layer, and input system. Your MCP client connects over that WebSocket and every tool runs in-process.

No swizzling. No private API wrappers. No SDK to integrate. Works with any app you can run in the simulator.

### Touch Input

All touch interactions — tap, scroll, swipe, gesture — use a single HID event injection pipeline. One code path for UIKit and SwiftUI. No accessibility hacks, no coordinate guessing.

### Adapters

For app-specific features (deep link routing, icon mappings, custom tools), Pepper supports **adapters** — optional modules compiled alongside the dylib. Without an adapter, Pepper runs in generic mode and works with any app out of the box.

## Development

```bash
make setup         # install deps, git hooks
make test-deploy   # build test app + inject Pepper
make ping          # verify connection
```

Run `make help` for all targets. See `CLAUDE.md` for conventions.

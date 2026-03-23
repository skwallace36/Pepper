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

**Observe** — `look`, `screen`, `find`, `tree`, `layers`, `highlight`

**Interact** — `tap`, `scroll`, `scroll_to`, `swipe`, `gesture`, `input_text`, `toggle`, `navigate`, `back`, `dismiss`, `dialog`

**Debug** — `vars_inspect`, `heap`, `console`, `network`, `crash_log`, `timeline`, `animations`, `lifecycle`

**App State** — `defaults`, `clipboard`, `keychain`, `cookies`, `locale`, `flags`, `push`, `orientation`

**Automation** — `wait_for`, `wait_idle`, `record`, `deploy`, `build`, `iterate`

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

# Pepper

MCP server for iOS Simulator apps. Injects a dylib via `DYLD_INSERT_LIBRARIES`, starts a WebSocket server inside the app process, and exposes 50+ tools — view hierarchy, touch input, network interception, heap inspection.

## Quick Start

**Homebrew** (recommended):

```bash
brew install --HEAD skwallace36/pepper/pepper
```

Tap: [`skwallace36/homebrew-pepper`](https://github.com/skwallace36/homebrew-pepper)

**From source:**

```bash
git clone https://github.com/skwallace36/Pepper.git
cd Pepper
make setup
```

Add Pepper to your MCP client (Claude Code, Cursor, etc.):

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

Then ask your agent to `look` at the screen.

## How It Works

All touch input goes through IOHIDEvent injection — the same path real fingers take. `tap`, `scroll`, `swipe`, and `gesture` work identically for UIKit and SwiftUI without knowing which framework rendered the view.

## Tools

`look` · `tap` · `scroll` · `scroll_to` · `swipe` · `gesture` · `input_text` · `toggle` · `navigate` · `back` · `dismiss` · `dismiss_keyboard` · `dialog` · `screen` · `find` · `read_element` · `tree` · `layers` · `highlight` · `vars_inspect` · `heap` · `console` · `network` · `crash_log` · `timeline` · `animations` · `lifecycle` · `concurrency` · `constraints` · `responder_chain` · `timers` · `defaults` · `clipboard` · `keychain` · `cookies` · `storage` · `sandbox` · `locale` · `flags` · `push` · `orientation` · `status` · `wait_for` · `wait_idle` · `record` · `deploy` · `build` · `build_device` · `iterate` · `snapshot` · `diff` · `screenshot` · `hook` · `raw`

Parameter docs are built into each tool — your MCP client surfaces them automatically.

## Adapters

Optional app-specific modules for deep link routes, icon mappings, custom tab bar detection. Set `APP_ADAPTER_TYPE` and `ADAPTER_PATH` in `.env`. Without an adapter, Pepper runs in generic mode.

## Development

```bash
make help          # list all targets
make setup         # install deps, git hooks, venv
make test-deploy   # build test app + inject Pepper
make ping          # health check
make smoke         # run smoke tests
make demo          # interactive demo walkthrough
```

Architecture guide: [`dylib/DYLIB.md`](dylib/DYLIB.md) · Tool reference: [`tools/TOOLS.md`](tools/TOOLS.md) · Troubleshooting: [`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md)

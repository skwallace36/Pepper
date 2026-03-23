# Pepper

> Runtime control for iOS Simulator apps — no source modifications required.

Pepper hooks into any iOS Simulator app at runtime and gives your AI real visibility and control — inspect the UI, tap buttons, read state, intercept network traffic, and more.

No SDK. No code changes. Just run your app and connect.

## Demo

Add Pepper to your MCP client config (Claude Desktop, Cursor, etc.):

```
$ make deploy
...Launching com.example.MyApp on D3E4F5... with Pepper injection.
Control plane at ws://localhost:8813

$ python3 tools/pepper-ctl look
─── Screen ───────────────────────────────────────
[Button] "Settings"           (accessible, tap)
[Label]  "Welcome, Stuart"
[TextField] ""                (accessible, input)
──────────────────────────────────────────────────
```

Then point your agent at a running simulator app.

## 3-Step Install

**Prerequisites:** macOS, Xcode, Python 3.10+, a running iOS Simulator.

```bash
# 1. Set up dependencies and git hooks
make setup

# 2. Build Pepper and deploy it into your app
#    (set APP_BUNDLE_ID in .env first — see .env.example)
make test-deploy

# 3. Verify the control plane is responding
make ping
```

That's it. Pepper is now running inside your app.

**Add to Claude Code (MCP):** copy `.mcp.json` into your project root (or merge it with an existing one). Claude will discover Pepper's tools automatically on next launch.

---

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│  AI agent / Claude Code                                 │
│    ↓  MCP tool call (look, tap, scroll, ...)            │
├─────────────────────────────────────────────────────────┤
│  pepper-mcp  (Python, stdio MCP server)                 │
│    ↓  WebSocket JSON command  ws://localhost:8770–8869  │
├─────────────────────────────────────────────────────────┤
│  Pepper dylib  (Swift, injected via DYLD_INSERT_LIBS)   │
│  ┌──────────────┐  ┌─────────────────────────────────┐  │
│  │ PepperServer │  │ PepperDispatcher                │  │
│  │ (NWListener) │→ │  ├─ UI/UX commands (50+)        │  │
│  └──────────────┘  │  ├─ Network / heap / state      │  │
│                    │  └─ Simulator control            │  │
│                    └─────────────────────────────────┘  │
│    ↓  UIKit / accessibility / IOHIDEvent APIs           │
├─────────────────────────────────────────────────────────┤
│  iOS Simulator app  (any app, unmodified)               │
└─────────────────────────────────────────────────────────┘
```

**How injection works:** Pepper's `bootstrap.c` uses `__attribute__((constructor))` so dyld calls it before `main()`. The Swift bootstrap registers adapters, runs pre-main hooks, then waits for `UIApplication.didFinishLaunchingNotification` before starting the WebSocket server.

**Port discovery:** Each simulator gets a deterministic port via `8770 + md5(UDID)[:4] % 100`. Ports are written to `/tmp/pepper-ports/<UDID>` so tools auto-discover them without configuration.

All interactions (tap, scroll, swipe, etc.) go through a single HID-based pipeline.

That means:

- Works the same for UIKit and SwiftUI
- No accessibility hacks
- No guessing screen coordinates

---

For app-specific behavior (deep links, custom mappings, etc.), you can add adapters.

They're optional. Without one, Pepper runs in a generic mode that works with any app.

## Tool Reference

All tools are available as MCP tools (via `pepper-mcp`) and CLI commands (via `pepper-ctl`).

### Observation

| Tool | Description |
|------|-------------|
| `look` | Structured map of all visible elements — labels, types, frames, interactability. Primary observation tool. |
| `tree` | Full accessibility tree dump |
| `screen` | Screenshot (PNG) |
| `find` | Find elements matching a query |
| `read_element` | Read a single element's full properties |
| `layers` | View hierarchy with layer info |
| `highlight` | Highlight elements on screen |

### Interaction

| Tool | Description |
|------|-------------|
| `tap` | Tap by label, identifier, or coordinates |
| `scroll` | Scroll a container in a direction |
| `scroll_to` | Scroll until a target element is visible |
| `swipe` | Swipe gesture from/to coordinates |
| `gesture` | Arbitrary multi-point gesture |
| `input_text` | Type text into focused field |
| `toggle` | Toggle a switch or checkbox |
| `dismiss` | Dismiss a modal or sheet |
| `dismiss_keyboard` | Hide the software keyboard |
| `dialog` | Interact with alerts and action sheets |

### Navigation

| Tool | Description |
|------|-------------|
| `navigate` | Trigger a deep link |
| `back` | Navigate back (pop or dismiss) |

### State Inspection

| Tool | Description |
|------|-------------|
| `vars_inspect` | Read arbitrary properties on a live object |
| `heap` | Query live heap objects by class pattern |
| `defaults` | Read/write `NSUserDefaults` |
| `clipboard` | Read/write the pasteboard |
| `keychain` | Read keychain items |
| `cookies` | Read HTTP cookies |
| `flags` | Read feature flags |

### Debugging

| Tool | Description |
|------|-------------|
| `console` | Tail app logs |
| `network` | Show HTTP request/response traffic |
| `crash_log` | Fetch latest crash report |
| `timeline` | Replay the event flight recorder |
| `animations` | Inspect animation state |
| `lifecycle` | View controller lifecycle events |

### Simulator Control

| Tool | Description |
|------|-------------|
| `orientation` | Set device orientation |
| `locale` | Override locale/region |
| `push` | Send a simulated push notification |
| `status` | Override status bar values |
| `simulator` | Run arbitrary `simctl` operations |
| `hook` | Install an ObjC method hook at runtime |

### Build & Deploy

| Tool | Description |
|------|-------------|
| `build` | Compile the app with `xcodebuild` |
| `build_device` | Compile for a physical device |
| `deploy` | Install app with Pepper injected |
| `iterate` | Build → deploy → verify in one step |

### Utilities

| Tool | Description |
|------|-------------|
| `wait_for` | Wait for an element or condition |
| `wait_idle` | Wait for UI to settle |
| `record` | Record simulator to MP4 or GIF |
| `raw` | Send any WebSocket command directly |

---

## Configuration

Copy `.env.example` to `.env` and set your app's bundle ID:

```bash
APP_BUNDLE_ID=com.example.yourapp
```

**Optional adapters:** For app-specific deep links, icon mappings, and custom tools, set:

```bash
APP_ADAPTER_TYPE=myapp
ADAPTER_PATH=/path/to/adapter
```

Without an adapter, Pepper runs in generic mode (works with any app).

---

## CLI Reference

`pepper-ctl` is a lightweight CLI for manual testing and scripting:

```bash
python3 tools/pepper-ctl look                   # screen summary
python3 tools/pepper-ctl tap --text "Settings"  # tap by label
python3 tools/pepper-ctl --json look            # raw JSON output
python3 tools/pepper-ctl --port 8813 ping       # specific port
python3 tools/pepper-ctl --simulator <UDID> look  # target simulator
```

---

## Make Targets

Run `make help` to see all targets. Key ones:

| Target | Description |
|--------|-------------|
| `make setup` | Install prereqs, Python deps, git hooks |
| `make build` | Compile `Pepper.framework` (seconds) |
| `make launch` | Launch app with Pepper injected |
| `make deploy` | Build + launch (most common workflow) |
| `make ping` | Verify control plane is responding |
| `make test-deploy` | Build test app + inject Pepper |
| `make lint` | Swift + Python linting |
| `make fmt` | Auto-format Swift + Python |

---

## Development

See [`CLAUDE.md`](CLAUDE.md) for development conventions, architecture notes, and how to add new commands.

Source layout:

```
dylib/        Swift dylib source (injected into app)
tools/        Python MCP server + CLI tools
test-app/     Xcode test app + coverage matrix
scripts/      Build and agent scripts
```

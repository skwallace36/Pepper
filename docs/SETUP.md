# pepper Setup

## Prerequisites

- macOS with Xcode 15+
- iOS Simulator (ships with Xcode)
- Python 3 with `websockets` (`pip3 install websockets`)
- Node.js 18+ (for the dashboard)
- Rust / Cargo (for the Tauri backend — install via [rustup](https://rustup.rs))

## Quick Start

```bash
# 1. Clone pepper
git clone <pepper-repo-url>
cd pepper

# 2. Boot a simulator (if one isn't already booted)
open -a Simulator

# 3. Deploy (build dylib + inject into app + start services)
make deploy

# 4. Verify
make ping
```

If `make ping` returns `{"pong": true}`, you're live.

## How It Works

Pepper is a **dylib** injected into the target iOS app at simulator launch via `DYLD_INSERT_LIBRARIES`. No source patches or workspace modifications needed.

1. `make build` compiles the Swift control plane (`control/`) into `build/Pepper.framework/Pepper`
2. `make launch` boots the simulator, terminates any existing app process, and launches with the dylib injected
3. The dylib starts a WebSocket server on `ws://localhost:8765` inside the app process

## Step by Step

### 1. Build the dylib

```bash
make build
```

This compiles `control/{server,commands,bridge}/*.swift` into a standalone framework dylib. Takes a few seconds.

### 2. Launch with injection

```bash
make launch
```

Terminates any running instance, boots the simulator if needed, and launches the app with Pepper injected via `DYLD_INSERT_LIBRARIES`.

### 3. Start services

```bash
make services
```

Starts the Tauri dashboard (port 1420, with API backend on port 8767) and BLE proxy daemon (port 8766). Both are idempotent — safe to re-run.

### 4. Use it

```bash
make ping                              # health check

# Or use pepper-ctl directly:
python3 tools/pepper-ctl ping
python3 tools/pepper-ctl look                                              # compact screen summary
python3 tools/pepper-ctl tap --text "Settings"                             # tap by label
python3 tools/pepper-ctl raw '{"cmd":"introspect","params":{"mode":"map"}}' # full JSON
```

Or do it all at once:

```bash
make deploy    # build + launch + services
```

## Configuration

Create a `.env` file in the project root (optional — defaults work for most setups):

```bash
BUNDLE_ID=com.example.app        # App bundle ID (override for your app)
PORT=8765                        # WebSocket port (default)
```

The simulator UUID is detected dynamically from `xcrun simctl list devices booted`. No need to configure it.

## Fresh Simulator Install

After a fresh app install (new simulator or app was deleted), you may need to complete the app's onboarding flow manually. This is app-specific — see the active adapter docs (e.g. `docs/fi/`) for details.

Most apps auto-login from keychain on subsequent relaunches.

## Troubleshooting

**"Connection refused"**
- Is the app running? `make launch`
- Check for a stale process holding the port: `lsof -i :8765 -sTCP:LISTEN`
- Kill it and relaunch: `make kill && make launch`

**Build fails**
- Make sure Xcode command-line tools are installed: `xcode-select --install`
- Try a clean build: `make clean && make build`

**"Element not found"**
- Use `pepper-ctl` to see what's on screen: `python3 tools/pepper-ctl raw '{"cmd":"introspect","params":{"mode":"map"}}'`
- The element may be on a different screen: `python3 tools/pepper-ctl raw '{"cmd":"screen"}'`

**"No key window available"**
- The app needs a moment after launch. Wait 2-3 seconds, then retry.

**Dashboard won't start**
- Check if Tauri dependencies are installed: `cd dashboard && npm install`
- Check the log: `cat build/logs/dashboard.log`
- Make sure Rust is installed: `rustc --version`

**Port already in use**
- Find what's using it: `lsof -i :8765` / `lsof -i :8767`
- Kill stale processes: `make kill` for the app, `make services-stop` for services

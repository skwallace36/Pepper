# Pepper

Pepper gives AI agents eyes and hands inside iOS Simulator apps.

It injects a shared library into any running simulator app — no source changes, no SDK, no build step. Your agent sees the screen as structured data, taps buttons, inspects live objects, intercepts network calls, reads the heap, and debugs layout issues. Dylib injection requires the simulator; device support uses a different mechanism.

https://github.com/user-attachments/assets/42ab3f1b-21f8-48e6-820f-7ca4012fb03b

*Claude navigating and inspecting [Ice Cubes](https://github.com/Dimillian/IceCubesApp) (Mastodon client) with zero source access.*

Works with Claude Code · Cursor · Claude Desktop · any [MCP](https://modelcontextprotocol.io) client

## Quickstart

Requires macOS 14+, Python 3.10+, and an iOS Simulator runtime.

```bash
pip install pepper-ios
pepper-ctl deploy            # inject into the frontmost simulator app
pepper-ctl look              # see what's on screen
```

Then ask your agent:

> "Tap through the onboarding flow and make sure every screen looks right"

That's it. The agent uses Pepper's MCP tools to see, tap, and inspect — no extra config needed.

<details>
<summary>Other MCP clients (Cursor, Claude Desktop, etc.)</summary>

```json
{
  "mcpServers": {
    "pepper": {
      "command": "pepper-mcp"
    }
  }
}
```

</details>

<details>
<summary>Homebrew</summary>

```bash
brew install --HEAD skwallace36/pepper/pepper
```

Tap: [`skwallace36/homebrew-pepper`](https://github.com/skwallace36/homebrew-pepper)

</details>

## What It Does

```
$ pepper-ctl look
Screen: navigation_stack  (9 interactive, 4 text)

       seg  "Trending"                       → tap text:"Trending"
       btn  "Sheryl Weikal, Right wing tech bros: we love St..."
                                              → tap text:"Sheryl Weikal, Right wing tech bros: we ..."
       seg  "Settings"                       → tap text:"Settings"

$ pepper-ctl tap --text "Settings"
Action: Tapped Settings
Screen: navigation_stack  Title: "Settings"  (15 interactive, 3 text)

       btn  "App Icon"                       → tap text:"App Icon"
       btn  "Display Settings"              → tap text:"Display Settings"
       ...
```

Every element comes with its tap command. The agent sees the screen, acts, and gets the new state back in one round trip.

### Things you can ask your agent

These work against any app — no setup beyond `deploy`.

> "Why is this list empty? Check the network request and see what the API returned"

> "What objects are holding a reference to DeviceActuationService? I think it's leaking"

> "Switch to dark mode and look for any text that's invisible against the background"

> "The login button isn't responding — check the responder chain and see what's intercepting taps"

> "Profile the scroll performance on the feed. Is anything hitching?"

> "Read what's in the keychain after logout — nothing should be left"

> "Turn off the feature flag for new-nav and make sure the old flow still works"

View hierarchy, network interception, heap inspection, console capture, crash logs, performance profiling, accessibility audits, constraint debugging, keychain/UserDefaults/CoreData access, locale and orientation control, feature flags, push notifications — 60+ tools in total. Parameter docs are built into every tool; your MCP client surfaces them automatically.

## How It Works

Pepper uses macOS's dynamic linker (`DYLD_INSERT_LIBRARIES`) to load a dylib into the simulator process at launch. The dylib starts a WebSocket server on a local port. `pepper-mcp` connects to that WebSocket and translates MCP tool calls into commands executed inside the app.

Because it runs in-process, Pepper has access to the full view hierarchy, the ObjC runtime, live object graphs, network delegates, and the HID event system. All touch input goes through native input events (IOHIDEvent) — the same path real fingers take. No private APIs, no entitlements — just `dyld`.

## Development

[`dylib/DYLIB.md`](dylib/DYLIB.md) — architecture and adding commands · [`tools/TOOLS.md`](tools/TOOLS.md) — MCP tool layer · [`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md) — common issues

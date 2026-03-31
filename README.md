# Pepper

[![SafeSkill 60/100](https://img.shields.io/badge/SafeSkill-60%2F100_Use%20with%20Caution-orange)](https://safeskill.dev/scan/skwallace36-pepper)

Pepper gives AI agents eyes and hands inside iOS Simulator apps.

It injects a lightweight dylib into any running simulator app — no source changes, no SDK, no build step. The dylib opens a WebSocket server inside the app process, and your AI agent connects through MCP to see what's on screen, tap buttons, inspect state, intercept network calls, read the heap, and debug layout issues. Over 60 tools, all available through natural language.

https://github.com/user-attachments/assets/42ab3f1b-21f8-48e6-820f-7ca4012fb03b

*Claude navigating and inspecting [Ice Cubes](https://github.com/Dimillian/IceCubesApp) (Mastodon client) with zero source access.*

Works with Claude Code · Cursor · Claude Desktop · any MCP client

## Why

AI coding agents are powerful, but they're blind to what's actually happening in a running app. They can write code and read logs, but they can't see a broken layout, tap through a flow, or inspect why a view isn't updating. Pepper closes that gap.

Screenshots and vision models can show an agent what's on screen, but that's expensive in tokens and lossy in detail. Pepper returns structured data — every element, its type, its tap command — in a few hundred tokens instead of thousands. And because it runs inside the app process, it can do things vision never could: inspect live objects, intercept network calls, read the keychain, capture console output, profile performance.

It's also built for a second audience: developers who build surprisingly complex apps with AI but hit a wall when something breaks. If you've never opened Instruments or typed an LLDB command, Pepper gives you visibility into your app without learning traditional debugging tools.

## Install

```bash
pip install pepper-ios
```

This gives you `pepper-mcp` (the MCP server) and `pepper-ctl` (a CLI). If you're using Claude Code with the repo cloned, `.mcp.json` handles config automatically.

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

## What It Can Do

Once connected, your agent can:

- **See the screen** — structured view hierarchy, not just a screenshot. The agent knows every label, button, and text field, their frames, traits, and accessibility identifiers.
- **Interact like a user** — tap, scroll, swipe, type, toggle switches, dismiss keyboards. All touch input goes through IOHIDEvent injection, the same path real fingers take. Works identically for UIKit and SwiftUI.
- **Inspect runtime state** — read and mutate properties on live objects with `vars_inspect`. Check Core Data stores, UserDefaults, keychain entries, cookies, clipboard contents.
- **Debug what went wrong** — capture console output, intercept network traffic, read crash logs, profile performance, inspect the responder chain, audit accessibility, visualize view layers and constraints.
- **Control the environment** — change locale, push notifications, toggle dark mode, rotate the device, simulate network conditions, manage the simulator lifecycle.

Parameter docs are built into every tool — your MCP client surfaces them automatically.

```
$ pepper-ctl look
Screen: navigation_stack  (9 interactive, 4 text)

       seg  "Trending"                       → tap text:"Trending"
       btn  "Sheryl Weikal, Right wing tech bros: we love St..."
                                              → tap text:"Sheryl Weikal, Right wing tech bros: we ..."
       btn  "Michael W Lucas, Anthropic lost a class action ..."
                                              → tap text:"Michael W Lucas, Anthropic lost a class ..."
       seg  "Timeline"                       → tap text:"Timeline"
       seg  "Settings"                       → tap text:"Settings"

$ pepper-ctl tap --text "Settings"
Action: Tapped Settings
Screen: navigation_stack  Title: "Settings"  (15 interactive, 3 text)

       btn  "App Icon"                       → tap text:"App Icon"
       btn  "Display Settings"              → tap text:"Display Settings"
       btn  "Content Settings"              → tap text:"Content Settings"
       ...
```

Every element comes with its tap command. The agent sees the screen, acts on it, and gets the new state back — all in one round trip.

## How It Works

Pepper uses `DYLD_INSERT_LIBRARIES` to load a dylib into the simulator process at launch. The dylib starts a WebSocket server on a local port. The MCP server (`pepper-mcp`) connects to that WebSocket and translates MCP tool calls into commands the dylib executes inside the app.

Because it runs inside the process, Pepper has access to everything the app can see: the full view hierarchy, the Objective-C runtime, live object graphs, network delegates, and the HID event system. No private APIs, no entitlements, no jailbreak — just `dyld`.

## Adapters

Adapters are optional app-specific modules — deep link routes, icon mappings, custom tab bar detection. Without one, Pepper runs in generic mode and works with any app. Set `APP_ADAPTER_TYPE` and `ADAPTER_PATH` in `.env` to load one.

## Development

Architecture guide: [`dylib/DYLIB.md`](dylib/DYLIB.md) · Tool reference: [`tools/TOOLS.md`](tools/TOOLS.md) · Troubleshooting: [`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md)

## About This Project

Pepper is an open-source tool and a learning piece. It's built to be useful to the iOS community and to demonstrate what's possible when you give AI agents deep runtime access to native apps. Fork it, rip it apart, adapt it to your workflow.

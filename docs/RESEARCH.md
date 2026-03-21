# Research & Competitive

Ideas from analyzing: FLEX, Chisel, InjectionIII, Maestro, Appium, Frida, Mobile MCP, agent-device, XcodeBuildMCP, Apple Xcode MCP.

## What Pepper Does That Nobody Else Does

1. 8-phase element discovery (a11y + UIKit + CALayer + icon catalog + spatial + noise filtering)
2. Perceptual icon matching (CUICatalog + multi-scale dHash + background subtraction)
3. Tap commands embedded in `look` output — AI reads `tap text:"Continue"` directly
4. In-process HTTP interception with structured JSON + request bodies
5. Heap snapshot diffing via malloc zone enumeration
6. ViewModel mutation triggering live SwiftUI re-render
7. Passive health monitoring (memory, leaks, network overfiring) in every `look` call

## Worth Building

| Idea | Source | Notes |
|------|--------|-------|
| Touch failure debugging | Chisel `presponder` | Gesture recognizer stack, responder chain, hit-test path |
| Layout inspector | Chisel `paltrace` | AutoLayout constraint dump + ambiguity detection |
| AX notification observer | Hammerspoon | Replace polling with event-driven screen change detection |
| In-process view capture | swift-snapshot-testing | `drawHierarchy(in:)` — faster than simctl, per-view |
| Network condition simulation | agent-device | URLProtocol throttling — 3g, edge, lossy presets |
| WebView inspection | Multiple | `evaluateJavaScript` on WKWebView — main-thread deadlock risk |
| Property change tracking | Original | `vars set` + cascade tracking — what changed, old/new values |
| Performance profiling | Original | FPS counter, main thread blocking, expensive redraws |
| Accessibility audit | Original | Missing labels, invalid traits, color contrast, Dynamic Type |

## Not Worth Building

| Idea | Why Not |
|------|---------|
| File system / SQLite browsing | Most apps are API-driven |
| Function hooking / raw memory | Frida exists |
| Android support | Different architecture entirely |
| WebDriver protocol | MCP is better |
| Record-and-playback / YAML tests | AI agent is the test runner |
| Cloud device farms | Orthogonal infrastructure |
| 3D view hierarchy | Visual debugging for humans, not AI |

## Sources

- [FLEX](https://github.com/FLEXTool/FLEX) — heap scanning, class browser, property editing
- [Chisel](https://github.com/facebook/chisel) — responder chain, layout trace
- [InjectionIII](https://github.com/johnno1962/InjectionIII) — function interposing
- [Maestro](https://github.com/mobile-dev-inc/Maestro) — relative element matching
- [Appium](https://github.com/appium/appium-xcuitest-driver) — NSPredicate queries
- [XcodeBuildMCP](https://github.com/getsentry/XcodeBuildMCP) — Xcode automation MCP
- [Apple Xcode MCP](https://developer.apple.com/documentation/xcode/giving-agentic-coding-tools-access-to-xcode)

---

**Routing:** Bugs → `../BUGS.md` | Work items → `../ROADMAP.md` | Test coverage → `../test-app/COVERAGE.md`

# Competitive Feature Tracker

Capabilities identified from deep analysis of: Mobile MCP, AXe, FLEX, Frida, Maestro, Appium, agent-device, XcodeBuildMCP.

Status: done, built (needs testing), tested, planned, won't do

---

## Done (existed before competitive analysis)

| Capability | Source inspiration | Pepper implementation |
|---|---|---|
| Accessibility tree walking | All tools | IntrospectHandler (internal, not external XCTest) |
| UIKit view hierarchy | FLEX | IntrospectHandler Phase 2, TreeHandler |
| CALayer inspection | FLEX | LayersHandler, IntrospectCardProbing |
| Heap object scanning | FLEX, Frida | HeapHandler (classes, controllers, find, inspect) |
| ViewModel read/write | FLEX (manual UI) | VarsHandler (list, get, set, dump, mirror) |
| Network interception | FLEX | NetworkHandler (URLProtocol swizzle, structured output) |
| Console capture | FLEX | ConsoleHandler (stderr ring buffer) |
| Animation scanning | Frida (manual hooks) | AnimationsHandler (scan, trace) |
| HID event synthesis | AXe (SimulatorKit) | PepperHIDEventSynthesizer (IOHIDEvent) |
| Icon matching | Nobody | PepperIconCatalog (dHash, background subtraction) |
| Multi-phase element discovery | Nobody | IntrospectHandler (8-phase pipeline) |
| MCP server | Mobile MCP, XcodeBuildMCP | pepper-mcp (39 tools) |
| Tap by text/icon/heuristic | Nobody else combines all | TapHandler |
| Spatial tap (right_of, etc.) | Maestro (partial) | TapHandler |
| Deep linking | Maestro, Appium | NavigateHandler |
| Tab switching | Nobody else | NavigateHandler |
| Nav stack pop | Nobody else | BackHandler, NavigateHandler |
| System dialog handling | agent-device, Appium | DialogHandler |
| Push notification sim | Appium, agent-device | PushHandler |
| App lifecycle sim | Appium | LifecycleHandler |
| Orientation control | Mobile MCP, Appium | OrientationHandler |
| Locale control | Appium | LocaleHandler |
| Pinch/rotate gestures | Appium | GestureHandler |
| Video recording | All | RecordHandler |
| Animation speed control | Nobody else | Merged into animations MCP tool |
| Build + deploy | XcodeBuildMCP (broader) | build/iterate/deploy MCP tools |

## Built (needs testing on more apps)

| Capability | Source | Commit | Status |
|---|---|---|---|
| App install/uninstall | Mobile MCP, Appium | `9715163` | built |
| Location simulation | Maestro, Appium | `9715163` | built |
| Permission grant/revoke/reset | Maestro, Appium, agent-device | `9715163` | built |
| Biometric simulation | Appium, agent-device | `9715163` | built |
| Privacy reset (all) | Appium | `9715163` | built |
| Open URL in sim | Mobile MCP, Appium | `9715163` | built |
| Boot/shutdown/erase sim | Mobile MCP, agent-device | `9715163` | built |
| Status bar override | agent-device | `9715163` | built |

## Tested (verified on device)

| Capability | Source | Commit | Verified |
|---|---|---|---|
| UserDefaults list/get/set/delete | FLEX | `76ef0de` | Full lifecycle: list → get → set → delete → verify gone |
| Keychain list/get/set/delete/clear | FLEX | `8bf3747` | Full lifecycle: list → get → set → delete → verify |
| Clipboard get/set/clear | Appium, agent-device | `8bf3747` | Set "pepper test", read back, clear, verify empty |
| Cookie list/get/delete/clear | FLEX | `8bf3747` | Listed 4 app cookies, deleted i18next, verified 3 remaining |
| Double tap | Mobile MCP, Appium | `8bf3747` | HID double-tap on Steps card |
| Long press | AXe, Appium | `8bf3747` | 1s hold on Steps card, navigated to detail |
| SwiftUI screen name extraction | Nobody | `b366b16` | home_view, health_view, rankings_tab_view all clean |
| Heap snapshot diffing (malloc zones) | FLEX | `d1f64e1` | Found 297 classes/1958 instances. Identified networking object growth. |
| Passive memory tracking | Nobody | `c97bd39` | memory_mb in look output, delta in telemetry |
| Automatic leak detection | Nobody | `5d45564` | Per-screen heap diffs, tested across all tabs + menu screens. No leaks found (correct). |
| Screen fingerprinting | Nobody | `41336ef` | Type-erased screens get unique keys (fi:f7ae6c61, fi:50d62534, etc.) |
| Network overfiring detection | Nobody | `11a9f60` | Detected POST /graphql 7x in 2.3s during tab switching |
| Request body capture | Nobody (URLProtocol fix) | `4c29111` | GraphQL operationName now visible: HealthTrends, getSharingSession, etc. |
| Dynamic icon heuristics | Nobody | `156c506` | Auto-gen from icon name + adapter overrides. Tested: close_button, gift_button, light_button. |
| Screenshot command removed | N/A | `32a4b0e` | look is the only way to see |
| MCP tool consolidation | N/A | `9715163` | 37 → 39 tools with more capability (simctl wrapper, grouped actions) |

## Planned (worth building)

| Capability | Source | Effort | Notes |
|---|---|---|---|
| Network condition simulation | agent-device | Medium | URLProtocol-based throttling. Presets: 3g, edge, lossy. No sudo needed. |
| WebView content inspection | All struggle here | Hard | evaluateJavaScript on WKWebView. Main-thread deadlock risk. WebView-based screens are blind spots for native discovery. |
| Add media to sim | Appium | Small | simctl addmedia — add photos/videos to sim library. |
| App info query | Appium | Small | simctl appinfo — get install path, container, etc. |

## Deprioritized (low value or premature)

| Capability | Source | Reason |
|---|---|---|
| File system browsing | FLEX | Most apps are API-driven, not heavy local storage. |
| SQLite query exec | FLEX | CoreData/SwiftData not heavily used in modern apps. |
| Incremental snapshots | agent-device | Staleness risk outweighs token savings. Context windows are huge. |
| Diff snapshots | agent-device | Same staleness concern. |
| Hardware buttons | AXe, Appium | Lifecycle simulation already covers most use cases. |
| Clear app state | Maestro, Appium | Covered by simctl uninstall + reinstall. |
| AI-powered assertions | Maestro | In MCP mode the calling LLM evaluates naturally. Only needed for automated runner. |

## Stretch (high value, hard)

| Capability | Source | Effort | Notes |
|---|---|---|---|
| SSL pinning bypass | Frida | Hard | Hook URLSession delegate to skip cert validation. Useful for staging. |
| Object reference tracking | FLEX | Hard | Walk malloc zones to find all objects referencing a target. |

## Won't Do (wrong tool for the job)

| Capability | Source | Reason |
|---|---|---|
| Function hooking / method swizzling | Frida | Different tool class. Frida exists for this. |
| Raw memory read/write/scan | Frida | Reverse engineering, not testing. |
| Execution tracing (Stalker) | Frida | Instruments does this better. |
| Android support | Mobile MCP, Maestro, Appium | Fundamentally different architecture. |
| WebDriver protocol | Appium | Adds latency for zero benefit with MCP. |
| YAML test definitions | Maestro | AI agent is the test runner. |
| Real device support | Most competitors | Massive scope (frida-gadget or developer disk). |
| Record-and-playback | Appium Inspector | AI agent generates tests. |
| Cloud device farms | Corellium, Appetize | Orthogonal infrastructure. |
| 3D view hierarchy | FLEX, Reveal | Visual debugging for humans, not AI agents. |

---

## Pepper's Unique Moat (no competitor has these)

1. **8-phase element discovery pipeline** — accessibility + UIKit + CALayer + icon catalog + spatial analysis + noise filtering
2. **Perceptual icon matching** — dynamic CUICatalog discovery + multi-scale dHash + background subtraction
3. **CALayer custom control detection** — SwiftUI toggles, cards, interactive areas with zero accessibility footprint
4. **Depth-aware hit-test resolution** — 3-tier: on-screen+topmost, on-screen+any, off-screen fallback
5. **Tap commands embedded in output** — one round-trip, AI reads `tap text:"Continue"` from `look`
6. **ViewModel mutation triggering re-render** — read/write @Published, SwiftUI updates live
7. **In-process HTTP interception** — automatic URLProtocol-based capture with structured JSON + request bodies
8. **App adapter pattern** — per-app config (deep links, icons, tabs) without changing core code
9. **Passive health monitoring** — memory tracking, automatic leak detection, and network overfiring surfaced in every `look` call without explicit commands
10. **Heap snapshot diffing via malloc zone enumeration** — counts ALL live ObjC instances by class, architecture-agnostic (works for SwiftUI @Observable, Combine, coordinators, anything)
11. **Screen fingerprinting** — type-erased SwiftUI screens get unique identity from element labels, enabling per-screen leak tracking

# Tasks

Agent-parseable work items. Referenced by `ROADMAP.md` for priorities.

Format: `TASK-NNN` ID, priority tag, `status:<status>`, description.
Statuses: `unstarted` → `in-progress` → `pr-open` → `done`.

## Test Coverage (P2)

Run every Pepper command against the test app. Each task covers a command family. Update `test-app/coverage-status.json` with results.

- **TASK-010** `[P2]` `status:pr-open` — Test `tap` variants: element, point, icon_name, tab, heuristic, predicate *(3 pass, 2 fail, 1 blocked)*
- **TASK-011** `[P2]` `status:pr-open` — Test `scroll` variants: top, bottom, up, left, right *(3 pass, 2 blocked)*
- **TASK-012** `[P2]` `status:pr-open` — Test `scroll_to` variants: element, text, predicate, edge *(4 tested → pass, BUG-004 filed)*
- **TASK-013** `[P2]` `status:pr-open` — Test `swipe` variants: up, down, left, right *(4 pass)*
- **TASK-014** `[P2]` `status:pr-open` — Test `input` + `toggle` commands *(1 pass, 1 fail)*
- **TASK-015** `[P2]` `status:pr-open` — Test `wait_for` variants: visible, exists, has_value *(3 fail — BUG-007, BUG-006)*
- **TASK-016** `[P2]` `status:pr-open` — Test `tree` + `read` + `find` commands *(8 pass)*
- **TASK-017** `[P2]` `status:pr-open` — Test `vars` variants: discover, list, get, set, dump, mirror *(6 pass, BUG-003 verified fixed)*
- **TASK-018** `[P2]` `status:pr-open` — Test `heap` + `heap_snapshot` commands *(8 pass)*
- **TASK-019** `[P2]` `status:pr-open` — Test `layers` + `introspect` commands *(8 pass introspect, 1 pass layers, BUG-002 verified fixed)*
- **TASK-020** `[P2]` `status:pr-open` — Test `console` + `network` + `timeline` commands *(13 pass, 1 prior pass)*
- **TASK-021** `[P2]` `status:pr-open` — Test `lifecycle` + `orientation` commands *(8 pass)*
- **TASK-022** `[P2]` `status:pr-open` — Test `defaults` + `keychain` + `cookies` + `clipboard` commands *(16 pass)*
- **TASK-023** `[P2]` `status:pr-open` — Test `dialog` + `hook` + `locale` + `push` commands *(14 pass, 2 blocked)*
- **TASK-024** `[P2]` `status:pr-open` — Test `navigate` deeplink + `batch` + `dismiss` + remaining *(18 pass, 3 fail, 2 blocked — BUG-008 filed)*

## Real App Smoke Test — Ice Cubes (P2)

Inject Pepper into Ice Cubes (open source SwiftUI Mastodon client) to pressure-test against a complex real-world UI. Clone from https://github.com/Dimillian/IceCubesApp, build, inject Pepper, run core commands.

- **TASK-027** `[P2]` `status:pr-open` — Clone Ice Cubes, build for simulator, inject Pepper, verify `look` works. Record what the element tree looks like for a real SwiftUI app (lazy lists, navigation stacks, tab bars, async images). *(BLOCKED by BUG-009: app crashes ~1s after injection due to PepperIconCatalog.build() calling UIImage on background thread)*
- **TASK-028** `[P2]` `status:pr-open` — Run `tap`, `scroll`, `navigate` against Ice Cubes. Document which commands work, which fail, and file bugs for failures. *(BLOCKED by BUG-009: app crashes on injection — cannot test any commands until fix lands)*
- **TASK-029** `[P2]` `status:pr-open` — Run `heap`, `vars`, `layers`, `network` against Ice Cubes. These are the deep introspection commands — stress test them against a real app's object graph and network traffic. *(BLOCKED by BUG-010: app crashes on injection due to PepperIconCatalog nil imageRef assertion — cannot test any commands until fix lands)*

## Test App Gaps (P2 prerequisite)

Test app changes needed before blocked commands can be tested. Unblocks ~20 untested variants.

- **TASK-025** `[P2]` `status:pr-open` — Add test app surfaces for blocked commands: URL scheme + deeplink routes, share button, rotation gesture view, UNNotification delegate, Localizable.strings, seed UserDefaults on launch, WKWebView with cookie, seed keychain entry
- **TASK-026** `[P2]` `status:pr-open` — Add horizontal scroll view to test app (unblocks `scroll left/right`, `scroll_to left/right`)

## Modularize `tools/` (P3)

### Extract shared library — `pepper_common.py`

- **TASK-060** `[P3]` `status:pr-open` — Extract `pepper_common.py`: `load_env()`, `get_config()`, `PORT_DIR` constant. Replace duplicates in pepper-mcp, pepper-ctl, pepper-stream, test-client.py
- **TASK-061** `[P3]` `status:pr-open` — Extract port discovery to `pepper_common.py`: `discover_port()`, `discover_simulator()`, `list_simulators()`. Consolidate 4 reimplementations (pepper-mcp, pepper-ctl, pepper-stream, test-client.py) into one with liveness checks
- **TASK-062** `[P3]` `status:pr-open` — Extract `pepper_format.py`: `format_look()` with optional ANSI color support. Deduplicate pepper-mcp (~150 lines) and pepper-ctl (~120 lines) formatting code
- **TASK-063** `[P3]` `status:pr-open` — Extract `pepper_websocket.py`: shared `send_command()` with event filtering, crash detection, ID matching. Deduplicate pepper-mcp and pepper-ctl WebSocket logic. Merge pepper-ctl's redundant `send_command()` / `send_and_recv_multi()`

### Split `pepper-mcp` into modules

- **TASK-064** `[P3]` `status:pr-open` — Extract `mcp_screenshot.py`: `capture_screenshot()` + quality modes (~80 lines)
- **TASK-065** `[P3]` `status:pr-open` — Extract `mcp_crash.py`: `_parse_crash_report()`, `_fetch_crash_info()` (~135 lines)
- **TASK-066** `[P3]` `status:pr-open` — Extract `mcp_telemetry.py`: `snapshot_counts()`, `gather_telemetry()`, `act_and_look()` (~230 lines)
- **TASK-067** `[P3]` `status:pr-open` — Extract `mcp_build.py`: simulator resolution, `_build_app()`, `_deploy_app()`, device build/deploy, `iterate()` (~560 lines)
- **TASK-068** `[P3]` `status:pr-open` — Extract `mcp_tools_nav.py`: tool definitions for look, tap, scroll, input, navigate, back, dismiss, swipe, screen, scroll_to, dismiss_keyboard (~200 lines)
- **TASK-069** `[P3]` `status:pr-open` — Extract `mcp_tools_state.py`: tool definitions for vars_inspect, defaults, clipboard, keychain, cookies (~120 lines)
- **TASK-070** `[P3]` `status:pr-open` — Extract `mcp_tools_debug.py`: tool definitions for layers, console, network, timeline, crash_log, animations, lifecycle, heap (~200 lines)
- **TASK-071** `[P3]` `status:pr-open` — Extract `mcp_tools_system.py`: tool definitions for push, status, highlight, orientation, locale, gesture, hook, find, flags, dialog, toggle, read_element, tree (~300 lines)
- **TASK-072** `[P3]` `status:pr-open` — Extract `mcp_tools_record.py`: `record()` tool + `_active_recordings` state (~130 lines)
- **TASK-073** `[P3]` `status:pr-open` — Extract `mcp_tools_sim.py`: `raw()`, `simulator()` tool definitions (~230 lines)

### Tools directory cleanup

- **TASK-074** `[P3]` `status:pr-open` — Audit and fix error handling: replace broad `except Exception` in pepper-context, standardize import error messages across all tools, validate external tool deps (rg, gh, xcodebuild)
- **TASK-075** `[P3]` `status:pr-open` — Update `tools/TOOLS.md` to document the new module layout and shared library

## CI/CD Integration (P4)

GitHub Actions workflow that boots a simulator, injects Pepper, and runs tests with reported results.

- **TASK-080** `[P4]` `status:unstarted` — Add `pepper-ctl wait-for-server` health check command (poll WebSocket until connected or timeout)
- **TASK-081** `[P4]` `status:unstarted` — Add JUnit/JSON test result export to `pepper-ctl` for CI artifact collection
- **TASK-082** `[P4]` `status:unstarted` — Create GitHub Actions workflow template: build dylib, boot headless sim, inject via `deploy`, run smoke tests, upload results
- **TASK-083** `[P4]` `status:unstarted` — Add CI batch/headless mode — run a predefined test script and exit with pass/fail status code
- **TASK-084** `[P4]` `status:unstarted` — Add `make ci` target that wraps the full boot → inject → test → teardown cycle

## Device Support (P5)

Extend Pepper from simulator-only to real iOS devices via build-time framework embedding.

- **TASK-085** `[P5]` `status:unstarted` — Add `make xcframework` target — package Pepper dylib as an xcframework for device embedding
- **TASK-086** `[P5]` `status:unstarted` — Add Bonjour service advertisement to `PepperServer` for device-to-host discovery (+ `NSLocalNetworkUsageDescription` docs)
- **TASK-087** `[P5]` `status:unstarted` — Add non-simulator port resolution fallback — explicit env var, Info.plist key, or Bonjour browse
- **TASK-088** `[P5]` `status:unstarted` — Update `pepper-ctl` and `pepper-mcp` to discover and connect to device-hosted Pepper instances (not just simulator ports)
- **TASK-089** `[P5]` `status:unstarted` — Document device integration guide — how to embed Pepper framework in an Xcode project for on-device use

## Packaging & Distribution (P6)

README, Homebrew, MCP directory listings.

- **TASK-090** `[P6]` `status:unstarted` — Write README with animated demo GIF/video, 3-step install, architecture diagram, tool reference table
- **TASK-091** `[P6]` `status:unstarted` — Create Homebrew tap repo (`homebrew-pepper`) with formula + GitHub Actions for automated bottle building
- **TASK-092** `[P6]` `status:unstarted` — Submit to MCP directories: mcp.so, awesome-mcp-servers (wong2 + punkpeye), Cline marketplace, official MCP registry, Glama, PulseMCP
- **TASK-093** `[P6]` `status:unstarted` — Record 60-second demo video showing Claude Code using Pepper to observe and interact with an iOS app
- **TASK-094** `[P6]` `status:unstarted` — Write technical blog post: "How I Gave AI Eyes Inside iOS Apps" — dylib injection approach, MCP integration, what it enables

## Android Port Prep (P3)

Restructure the iOS dylib for platform abstraction. Each phase is independently committable. iOS keeps working at every step. Full plan: `docs/plans/ANDROID-PORT.md`.

### Phase A: Platform protocols + core types

- **TASK-100** `[P3]` `status:pr-open` — Create `dylib/platform/` with `PepperPlatform.swift` (factory protocol), `ElementDiscovery.swift`, `InputSynthesis.swift`, `StateObservation.swift`. Pure addition, no existing code changes.
- **TASK-101** `[P3]` `status:pr-open` — Add remaining platform protocols: `NetworkInterception.swift`, `DialogDetection.swift`, `NavigationBridge.swift`, `ViewIntrospection.swift`, `WebSocketTransport.swift`. *(blocked by TASK-100)*
- **TASK-102** `[P3]` `status:pr-open` — Create `dylib/core/PepperGeometry.swift` with platform-agnostic `PepperPoint`/`PepperRect` (midX/midY, contains, intersects). Add `#if canImport(UIKit)` CGRect/CGPoint bridging extensions.

### Phase B: iOS platform wrappers

- **TASK-110** `[P3]` `status:unstarted` — Create `IOSPlatform.swift` factory + add `platform` property to `PepperPlane.shared`. Wire it up in `start()`. *(blocked by TASK-100, TASK-101)*
- **TASK-111** `[P3]` `status:unstarted` — Create `IOSElementDiscovery` wrapping `PepperSwiftUIBridge.shared` + `PepperAccessibilityCollector` + `PepperElementResolver`. *(blocked by TASK-110)*
- **TASK-112** `[P3]` `status:unstarted` — Create `IOSInputSynthesis` wrapping `PepperHIDEventSynthesizer.shared` (tap, doubleTap, scroll, swipe, gesture, inputText, toggle). *(blocked by TASK-110)*
- **TASK-113** `[P3]` `status:unstarted` — Create `IOSStateObservation` wrapping `PepperState.shared` + `PepperIdleMonitor.shared` + `PepperScreenRegistry`. *(blocked by TASK-110)*
- **TASK-114** `[P3]` `status:unstarted` — Create `IOSNetworkInterception` wrapping `PepperNetworkInterceptor.shared`. *(blocked by TASK-110)*
- **TASK-115** `[P3]` `status:unstarted` — Create `IOSDialogDetection` wrapping `PepperDialogInterceptor.shared` + `IOSNavigationBridge` wrapping `PepperNavBridge` + `IOSViewIntrospection` wrapping existing layer/heap code. *(blocked by TASK-110)*

### Phase C: Migrate handlers to platform abstraction

- **TASK-120** `[P3]` `status:unstarted` — Migrate pure-logic handlers (~12): BatchHandler, SubscribeHandler, UnsubscribeHandler, WatchHandler, UnwatchHandler, TestHandler, HookHandler, TimelineHandler, MemoryHandler, HeapSnapshotHandler, StatusHandler, ConsoleHandler. No-op or trivial — verify they compile against platform API. *(blocked by TASK-110)*
- **TASK-121** `[P3]` `status:unstarted` — Migrate light-dep handlers (group 1, ~8): NetworkHandler, DefaultsHandler, ClipboardHandler, CookieHandler, KeychainHandler, LocaleHandler, DialogHandler, CurrentScreenHandler. Replace direct singleton calls with `platform.*`. *(blocked by TASK-111 through TASK-115)*
- **TASK-122** `[P3]` `status:unstarted` — Migrate light-dep handlers (group 2, ~7): PushHandler, OrientationHandler, LifecycleHandler, AnimationsHandler, VarsHandler, ReadHandler, HighlightHandler. *(blocked by TASK-111 through TASK-115)*
- **TASK-123** `[P3]` `status:unstarted` — Migrate heavy-dep handlers (input, ~7): TapHandler, ScrollHandler, ScrollUntilVisibleHandler, SwipeHandler, GestureHandler, InputHandler, ToggleHandler. Replace HID + element resolution calls. *(blocked by TASK-111, TASK-112)*
- **TASK-124** `[P3]` `status:unstarted` — Migrate heavy-dep handlers (navigation, ~5): NavigateHandler, DeeplinkHandler, BackHandler, DismissHandler, DismissKeyboardHandler. *(blocked by TASK-111, TASK-115)*
- **TASK-125** `[P3]` `status:unstarted` — Migrate heavy-dep handlers (introspection, ~9): FindHandler, IntrospectHandler, IntrospectMapHelpers, IntrospectModes, IntrospectCardProbing, TreeHandler, LayersHandler, IdentifyIconsHandler, IdentifySelectedHandler, IdleWaitHandler. *(blocked by TASK-111, TASK-113, TASK-115)*

### Phase D–F: Core extraction + server split + reorg

- **TASK-130** `[P3]` `status:unstarted` — Extract core geometry into `PepperElementTypes.swift`: replace `CGRect`/`CGPoint` with `PepperPoint`/`PepperRect`, remove `import UIKit` from data models, add `#if canImport(UIKit)` convenience inits. *(blocked by TASK-102)*
- **TASK-131** `[P3]` `status:unstarted` — Split `PepperServer.swift`: extract `WebSocketTransport` protocol, create `NWListenerTransport` wrapping existing NWListener code (lines 1-170). Core server logic (lines 215-380) takes transport via init. *(blocked by TASK-101)*
- **TASK-132** `[P3]` `status:unstarted` — Directory reorganization: move iOS-specific files into `dylib/ios/`, core files into `dylib/core/`, update build script source paths. *(blocked by all above — do last)*

## Generic Mode Cleanup (P7)

- **TASK-030** `[P7]` `status:done` — Fix build script when APP_ADAPTER_TYPE is unset (`set -u` + unbound var) *(PR #6, merged)*
- **TASK-031** `[P7]` `status:unstarted` — Audit core code for app-specific assumptions that break in generic mode
- **TASK-032** `[P7]` `status:unstarted` — Generic mode smoke test script (`make test-generic`) — build, inject, run core commands, assert no crashes
- **TASK-033** `[P7]` `status:unstarted` — Audit error messages for adapter-specific language that confuses generic mode users

## Real-World App Testing (P8)

- **TASK-040** `[P8]` `status:unstarted` — Test Pepper against Wikipedia iOS app
- **TASK-041** `[P8]` `status:unstarted` — Test Pepper against Ice Cubes (SwiftUI Mastodon client)

## New Capabilities (P9)

Ideas from `docs/RESEARCH.md` promoted to concrete tasks.

- **TASK-050** `[P9]` `status:unstarted` — Accessibility audit command — scan for missing a11y labels, invalid traits, insufficient color contrast, Dynamic Type issues
- **TASK-051** `[P9]` `status:unstarted` — Touch failure debugging — dump gesture recognizer stack, responder chain, hit-test path for a given point or element
- **TASK-052** `[P9]` `status:unstarted` — Layout inspector — AutoLayout constraint dump with ambiguity detection (inspired by Chisel `paltrace`)
- **TASK-053** `[P9]` `status:unstarted` — Performance profiling — FPS counter, main thread blocking detection, expensive redraw identification
- **TASK-054** `[P9]` `status:unstarted` — In-process view capture via `drawHierarchy(in:)` — faster than simctl, supports per-view snapshots

---

**Routing:** Bugs → `BUGS.md` | Priorities → `ROADMAP.md` | Test results → `test-app/COVERAGE.md` | Research → `docs/RESEARCH.md`

# Pepper Roadmap — Dev-Focused Improvements

Research from open source tools (FLEX, Chisel, InjectionIII, Maestro, Appium), Apple's Xcode MCP, and the broader AI-powered dev tool ecosystem.

## Done

### Pepper MCP Server
17 native MCP tools (`look`, `tap`, `vars_inspect`, `heap`, `deploy`, etc.) available to Claude Code via `.mcp.json`. No shell commands needed — Claude calls tools directly.

### Heap Scanning
`heap` command with 4 actions: `classes` (enumerate loaded classes by pattern), `controllers` (live VC hierarchy), `find` (singleton discovery), `inspect` (mirror dump). Classes and controllers work well. Find/inspect need iteration for pure Swift singletons.

### NSPredicate Element Queries
`find` command queries on-screen elements using native iOS NSPredicate format strings. Full property access: label, type, className, traits, frame, heuristic, iconName, viewController, etc. Also available as a `predicate` tap strategy. ObjC exception catching for safe format validation.

### Runtime Method Hooking
`hook` command installs transparent method hooks on any ObjC method at runtime. Logs invocations with timestamp, receiver, class, and argument values. Supports void/object/BOOL return × mixed arg types. Built on existing fishhook/swizzle infrastructure.

### Xcode MCP Bridge (Parked)
Apple's `xcrun mcpbridge` requires XPC injection into a running Xcode process. Doesn't work reliably with current setup — beta Xcode 26.3 feature. Revisit when stable. Existing build scripts + Pepper cover the same workflow.

## Tier 1: High Value

### PR Test Plan Validation
Automated validation of PR test plan items with visual proof (screenshots + video). The workflow:
1. Read PR description → parse test plan checkboxes into actionable steps
2. For each item: navigate to the relevant screen, perform the interaction, capture evidence
3. Upload screenshots/video, check off items, update PR description

**What works today:**
- Feature flag toggle via network response interception (`flags set` + `deploy`)
- Screenshots via `look save_screenshot` + `upload-screenshot --repo`
- Screen recording via `simctl recordVideo` → ffmpeg → compressed mp4/gif
- Tight recording chains: explore with `look`, then script taps with animation delays
- PR description updates via `gh pr edit`

**Video upload solved:**
- Playwright MCP connects to Chrome with persistent user-data-dir (`~/.pepper/chrome-profile`)
- One-time login (user logs in via the Playwright-launched Chrome), session persists across runs
- Upload flow: navigate to PR → click "attach files" → `browser_file_upload` → read `user-attachments` URL from textarea → clear textarea → `gh pr edit`
- Videos autoplay inline in PR descriptions

**Next steps:**
- Generalize beyond feature flags — any test plan item that describes a navigation + interaction + assertion
- Smart animation delay estimation per action type

### Touch Failure Debugging (from Chisel's `presponder`)
When a tap fails silently, expose why: gesture recognizer stack, responder chain, hit-test path. Chisel's `presponder` + `taplog` pattern. The dylib already has access to all of this.

### Layout Inspector (from Chisel's `paltrace`)
AutoLayout constraint dump + ambiguity detection. SwiftUI layout issues where views are invisible — walk the constraint system and report conflicts. Already accessible from inside the process.

## Tier 2: Worth Stealing

### AX Notification Observer (from Hammerspoon)
Replace polling for screen changes with event-driven `UIAccessibilityPostNotification` observers. More reliable, less overhead.

### In-Process View Capture (from swift-snapshot-testing)
`UIView.drawHierarchy(in:afterScreenUpdates:)` is faster than simctl screenshot and can capture individual views, not just full screen. Useful for visual regression on specific components.

### Hot Reload Detection (from Inject / InjectionIII)
If Inject is in the project, Pepper could detect it and trigger reloads after code changes. Edit → inject → `look` → verify, sub-second iteration loop.

### Relative Element Matching (from Maestro)
"Below text X, find button Y" as a formal selector. Pepper has spatial operators but Maestro's relational matching is more expressive.

### Property Change Tracking
`vars action:set` mutates but doesn't track cascades. A `property-log` that shows what changed, old/new values, and what re-rendered would make state debugging trivial.

### Performance Profiling
FPS counter, main thread blocking detection, expensive view redraws. Only `memory` exists today for basic stats.

### Accessibility Audit
Automated checks for missing labels, invalid trait combinations, color contrast, Dynamic Type testing. Can read a11y data today but doesn't audit it.

## Sources

- [FLEX (Flipboard Explorer)](https://github.com/FLEXTool/FLEX) — in-process heap scanning, class browser, property editing
- [Chisel (Facebook LLDB)](https://github.com/facebook/chisel) — responder chain, layout trace, render server layers
- [InjectionIII / HotReloading](https://github.com/johnno1962/InjectionIII) — function interposing via fishhook / dyld_dynamic_interpose
- [Maestro (mobile.dev)](https://github.com/mobile-dev-inc/Maestro) — relative element matching, XCTest HTTP server pattern
- [Appium XCUITest Driver](https://github.com/appium/appium-xcuitest-driver) — NSPredicate queries, class chain selectors
- [Hammerspoon](https://www.hammerspoon.org/docs/hs.axuielement.html) — AX notification observers
- [swift-snapshot-testing (Point-Free)](https://github.com/pointfreeco/swift-snapshot-testing) — in-process view capture, fuzzy diffing
- [Inject (Zablocki)](https://github.com/krzysztofzablocki/Inject) — SwiftUI hot reload
- [XcodeBuildMCP (Sentry)](https://github.com/getsentry/XcodeBuildMCP) — 59-tool Xcode automation MCP
- [Apple Xcode MCP](https://developer.apple.com/documentation/xcode/giving-agentic-coding-tools-access-to-xcode) — native mcpbridge, 20 built-in tools
- [Swift MCP SDK](https://github.com/modelcontextprotocol/swift-sdk)
- [XC-MCP](https://github.com/conorluddy/xc-mcp) — progressive disclosure pattern for context optimization

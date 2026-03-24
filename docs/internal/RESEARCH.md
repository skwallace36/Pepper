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

## Inter-Agent Communication Patterns (Issue #174)

Evaluated direct agent communication; GitHub-issues-as-bus is correct for embarrassingly parallel workload. Would revisit for multi-agent coordinated tasks.

## AttributeGraph Exploration (Issue #185)

### Background

SwiftUI uses a private framework called **AttributeGraph** (AG) to manage its dependency graph — every `@State`, `@Binding`, `@ObservedObject`, and computed body is a node, and edges represent "this depends on that." When a node changes, AG walks the dependency edges to invalidate and re-evaluate downstream nodes. If we can read this graph, we can answer "which `@State` property triggered this render" — the holy grail of SwiftUI debugging.

The current `renders` command (Phases 1-3) tracks render counts and view tree structure via `makeViewDebugData()`, but cannot explain *why* a re-render happened. Phase 4 investigates whether AG's private APIs can bridge that gap.

### APIs Investigated

#### 1. `AGGraphArchiveJSON(AGGraphRef, const char *name)`

**What it does:** Dumps the full attribute graph to a JSON file. The output contains all nodes (views, state properties, computed values) and their dependency edges.

**Implementation:** `PepperAGExplorer.m` resolves this via `dlsym(RTLD_DEFAULT, "AGGraphArchiveJSON")`. The critical prerequisite is obtaining an `AGGraphRef`, which we attempt to extract from `_UIHostingView` → `viewGraph` → `graph` via KVC and ivar walking.

**Expected behavior:** If the symbol is resolved and AGGraphRef extraction succeeds, the function writes a JSON file to the file system. The JSON structure (per OpenAttributeGraph reverse engineering) contains:
- `nodes[]`: Each node has a type (State, Binding, ViewBody, etc.), a value, and a list of dependency edges
- `edges[]`: Directed edges showing which nodes depend on which
- `attributes[]`: Metadata about each attribute (type name, offset, flags)

**Risk:** AGGraphRef extraction is the weak link. `_UIHostingView`'s internal layout changes across iOS versions. The `viewGraph` property may be a Swift struct (not KVC-accessible) or may not directly expose the raw C `AGGraphRef`.

**Status:** Code written, needs runtime validation. Run `renders ag_probe` then `renders ag_dump` in a simulator.

#### 2. `AGDebugServerStart()` / `AGDebugServerCopyURL()`

**What it does:** Starts an HTTP/WebSocket debug server embedded in the AttributeGraph framework. Instruments uses this to visualize the AG graph in real-time.

**Implementation:** Resolved via dlsym. `AGDebugServerStart()` is a void function with no arguments — it starts the server on an ephemeral port. `AGDebugServerCopyURL()` returns the URL (caller must `free()`).

**Expected behavior:** If the symbols exist, the server starts and exposes endpoints for querying graph structure and subscribing to update events. The protocol is undocumented; Instruments likely uses a custom binary format.

**Risk:** These symbols may only be present in debug builds of AttributeGraph (i.e., Xcode's internal SDK, not the simulator runtime). Even if present, the server may require additional AG initialization that only Instruments triggers.

**Status:** Code written. Run `renders ag_server` to attempt activation.

#### 3. AG Tracing API (`AGGraphSetTrace`, `AGGraphIsTracingActive`, `AGGraphPrepareTrace`)

**What it does:** A built-in tracing system that emits events when nodes are invalidated and re-evaluated. If active, it records the chain of invalidations — exactly what we need for "why did this re-render."

**Implementation:** Resolved via dlsym. Requires AGGraphRef. `AGGraphSetTrace(graphRef, 1)` would enable tracing; `AGGraphIsTracingActive(graphRef)` checks status.

**Risk:** Same AGGraphRef extraction challenge. The trace output destination is unknown — it may write to a file, emit signposts, or require a callback registration function we haven't identified.

**Status:** Symbols probed. Needs runtime testing.

#### 4. Signpost Introspection (`_os_signpost_set_introspection_hook_4Perf`)

**What it does:** SwiftUI emits `os_signpost` events under subsystem `com.apple.SwiftUI` for body evaluation, layout, and rendering. This private function in `libsystem_trace.dylib` installs a callback that receives all signpost events in-process — the same mechanism Instruments uses.

**Implementation:** Resolved via dlsym. We install a C callback (`signpostCallback`) that captures signpost events into a ring buffer. Events are filtered for SwiftUI-related signposts.

**Callback signature (believed):**
```c
void callback(uint64_t signpost_id, os_log_t log, uint8_t type,
              const char *name, const char *format, ...);
```

**Expected events:** `Body`, `ViewBody`, `Layout`, `Render`, `UpdateAttributes` — with timing information.

**Risk:** The callback signature is not stable across OS versions. A signature mismatch would crash the process. The function may also be stripped from release builds of `libsystem_trace`.

**Status:** Code written. Run `renders signpost sub:install` then trigger UI changes and `renders signpost sub:drain`.

#### 5. AGGraphRef Extraction Path

**What it does:** Gets the raw AG graph handle from a live `_UIHostingView` so we can call AG APIs on it.

**Approach:** Multiple strategies, tried in order:
1. `[hostingView valueForKey:@"viewGraph"]` — KVC on the hosting view
2. Ivar walking — enumerate all ivars of `_UIHostingView` and its superclasses, logging names and types

**Known challenges:** SwiftUI's `ViewGraph` is a Swift class, but its `graph` property may be:
- A computed property (not accessible via KVC)
- A stored property with name mangling
- A C pointer stored as a raw `UnsafeMutableRawPointer` (not bridgeable to ObjC `id`)

**Reference:** Saagar Jha's "Making Friends with AttributeGraph" documents using `_UIHostingView` → `ViewGraphOwner` protocol → `viewGraph` → accessing the graph. The exact ivar layout depends on iOS version.

### Additional Symbols Probed

The explorer also checks for these secondary AG symbols:

| Symbol | Purpose |
|--------|---------|
| `AGGraphCreate` | Create a new graph (unlikely to be useful — we want the existing one) |
| `AGGraphDestroy` | Destroy a graph |
| `AGGraphGetMainGraph` | Get the "main" graph — could bypass the _UIHostingView extraction entirely |
| `AGGraphDescription` | String description of a graph |
| `AGNodeCreate` / `AGNodeGetValue` | Individual node operations |
| `AGAttributeGetValue` / `AGAttributeSetValue` | Attribute read/write |
| `AGGraphAddTraceEvent` | Manually inject trace events |

`AGGraphGetMainGraph` is particularly interesting — if it exists and returns a valid ref, we can skip the _UIHostingView extraction entirely.

### How to Use

All exploration is exposed through the existing `renders` command:

```json
{"cmd":"renders","params":{"action":"ag_probe"}}
// → Reports which AG symbols are resolved on this iOS version

{"cmd":"renders","params":{"action":"ag_server"}}
// → Attempts to start the AG debug server

{"cmd":"renders","params":{"action":"ag_dump","name":"my_snapshot"}}
// → Dumps the AG graph to JSON (requires hosting view + AGGraphRef)

{"cmd":"renders","params":{"action":"signpost","sub":"install"}}
// → Installs the signpost introspection hook

{"cmd":"renders","params":{"action":"signpost","sub":"drain"}}
// → Returns captured signpost events

{"cmd":"renders","params":{"action":"why"}}
// → Best-effort render causality: combines diff + AG + signpost data
```

### Next Steps

1. **Runtime validation** — Run `ag_probe` on iOS 17, 18, and 26 simulators to build a compatibility matrix
2. **AGGraphRef extraction** — If KVC fails, try `object_getIvar` with manual offset calculation based on ivar dump
3. **Signpost callback safety** — If the callback signature is wrong, wrap in a signal handler to catch SIGSEGV gracefully
4. **Graph diff over time** — If `AGGraphArchiveJSON` works, capture graphs before/after state changes and diff the JSON
5. **`AGGraphGetMainGraph` shortcut** — If this symbol exists, it may provide the simplest path to the graph

### References

- [Making Friends with AttributeGraph — Saagar Jha](https://saagarjha.com/blog/2024/02/27/making-friends-with-attributegraph/)
- [Untangling the AttributeGraph — Rens Breur](https://rensbr.eu/blog/swiftui-attribute-graph/)
- [OpenSwiftUIProject/AGDebugKit](https://github.com/OpenSwiftUIProject/AGDebugKit)
- [OpenSwiftUIProject/OpenAttributeGraph](https://github.com/OpenSwiftUIProject/OpenAttributeGraph)
- [SwiftUI Secrets — Mike Apurin](https://apurin.me/articles/swiftui-secrets/)

---

**Routing:** Bugs → GitHub Issues (`gh issue list --label bug`) | Work items → `../ROADMAP.md` | Test coverage → `../test-app/COVERAGE.md`

# Pepper — Runtime App Control

Pepper is injected into the running simulator app. Use it to verify changes visually without screenshots.

## After every build + deploy

Run `look` to verify the change worked. Don't assume — check.

## Tool Quick Reference

### What do you want to do?

**See the screen** → `look` (always first, instead of screenshots)
**Interact** → `tap`, `scroll`, `swipe`, `scroll_to`, `gesture`, `input_text`
**Navigate** → `navigate` (deep link / tab), `back`, `dismiss`
**Build & deploy** → `iterate` (build+deploy+look), `build`, `deploy`

**Check runtime state** → Three complementary tools:
- `vars_inspect` — ViewModel @Published properties (runtime, in-memory)
- `defaults` — UserDefaults (persistent key-value store — test flags, debug modes, feature toggles)
- `keychain` — stored credentials and tokens

**Debug visuals** → `layers` (CALayer tree at a point), `highlight` (draw borders around elements)
**Debug behavior** → `console` (app logs), `network` (HTTP traffic), `heap` (live objects in memory)
**Debug animations** → `animations` (scan active, trace movement, control speed)

**Query elements** → `find` (NSPredicate queries), `read_element` (single element detail), `tree` (full view hierarchy)
**Control simulator** → `simulator` (location, permissions, biometrics, install/uninstall, boot/shutdown, status bar)
**Feature flags** → `flags` (override server-delivered flags via network interception)
**Record** → `record` (screen recording to mp4/gif)
**Escape hatch** → `raw` (send any Pepper command not wrapped by other tools)

---

## Tools by Category

### Seeing the Screen
- **`look`** — see what's on screen (all elements + tap commands). **Use this instead of screenshots. ALWAYS.** Add `visual=true` for a screenshot alongside structured data. Add `raw=true` for full JSON with coordinates/frames.

### Interaction
- **`tap`** — tap by text, icon, heuristic, or point. `double=true` for double-tap, `duration=1.0` for long press.
- **`scroll`** — scroll in a direction (slow drag)
- **`swipe`** — quick flick in a direction
- **`scroll_to`** — scroll until target text appears (combines scroll + visibility polling)
- **`gesture`** — multi-touch: pinch (zoom) or rotate. *Note: pinch may not work on all map views (e.g., GMSMapView) that use custom gesture recognizers.*
- **`input_text`** — type into a text field
- **`toggle`** — flip a UISwitch or advance a UISegmentedControl
- **`dismiss_keyboard`** — resign first responder

### Navigation
- **`navigate`** — deep link or tab switch. `list_deeplinks=true` to see all destinations.
- **`back`** — go back / dismiss current screen
- **`dismiss`** — dismiss topmost modal/sheet

### Building
- **`iterate`** — **(recommended)** build + deploy + look in one call
- **`build`** — compile only (no deploy)
- **`deploy`** — terminate + relaunch with Pepper injected (no rebuild)
- **`build_device`** — build + install + launch on physical device (no Pepper injection)

### App State (read & write without rebuilding)

Use these to inspect and change app state at runtime. **No print statements. No rebuilds.**

- **`vars_inspect`** — ViewModel @Published properties. `list` → `dump` → `mirror` → `set`. Re-scan with `discover` after code changes.
- **`defaults`** — Read/write NSUserDefaults. Use for: debug flags, test modes, feature toggles, any app config stored in UserDefaults. `list` (all keys), `get` (read), `set` (write, JSON-typed), `delete`.
- **`keychain`** — Stored credentials, tokens, secrets. `list`, `get`, `set`, `delete`, `clear`.
- **`cookies`** — HTTP cookies. `list`, `get`, `delete`, `clear`.
- **`clipboard`** — Device pasteboard. `get`, `set`, `clear`.

### Debugging

- **`console`** — App logs (print + NSLog). `start` capture, then `log` to read. Filter with `filter` param.
- **`network`** — HTTP traffic. `start` capture, then `log` to read. Shows URLs, status codes, response bodies. Filter with `filter` param.
- **`heap`** — Live objects in memory. Actions grouped by purpose:
  - *Discovery*: `classes` (search by pattern), `controllers` (live VCs), `find` (locate singletons via .shared/.default)
  - *Inspection*: `inspect` (full property dump), `read` (KVC property access — supports nested paths like `camera.zoom`)
  - *Leak detection*: `snapshot` (baseline VC counts) → `diff` (compare — if counts grow, there's a retain cycle)
- **`layers`** — CALayer tree at a point. Returns colors, gradients, shadows, transforms.
- **`animations`** — `scan` active animations, `trace` view movement over time, `speed` to slow/fast-forward.
- **`highlight`** — Draw colored borders around elements for visual debugging. `clear=true` to remove.
- **`lifecycle`** — Trigger `background`, `foreground`, or `memory_warning`.

### Element Queries
- **`find`** — Query elements with NSPredicate syntax. Properties: `label`, `type`, `value`, `heuristic`, `x`, `y`, `width`, `height`. Supports `tap` action to find-and-tap.
- **`read_element`** — Detailed info for one element by accessibility ID.
- **`tree`** — Full UIView hierarchy dump. Use `depth` to limit.

### Simulator Control
- **`simulator`** — Control the simulator itself (not the app):
  - `install` / `uninstall` — manage apps
  - `location` — set GPS coordinates
  - `permissions` — grant/revoke (camera, photos, notifications, etc.)
  - `biometrics` — enroll Face ID, trigger match/fail
  - `open_url` — open a URL in the sim
  - `boot` / `shutdown` / `erase` — manage sim lifecycle
  - `status_bar` — override time, battery, signal
  - `privacy_reset` — reset all privacy permissions

### Feature Flags
- **`flags`** — Override feature flags delivered via GraphQL. Intercepts the network response and modifies JSON before the app processes it. `set` a flag → `deploy` to apply. `clear` to remove overrides.

### Other
- **`hook`** — Log ObjC method invocations at runtime (transparent — original method still runs).
- **`push`** — Simulate push notifications.
- **`orientation`** — Get/set device orientation.
- **`locale`** — Override app locale, look up localized strings, list languages.
- **`record`** — Screen recording. `start` → interact → `stop output=/tmp/clip.mp4`.
- **`status`** — Device, app, and Pepper server info. Add `memory=true` for memory stats.
- **`raw`** — Send any Pepper command not covered by other tools.

---

## Rules

- **NEVER screenshot.** Not `xcrun simctl io screenshot`, not any visual capture. Use `look`.
- **`look` first, always.** Before tapping, navigating, or asserting.
- If `look` doesn't work, fix Pepper — don't fall back to screenshots.

## Debugging state — use `vars_inspect` BEFORE adding logs

When you need to understand runtime state (property values, whether a flag is set, ViewModel state):

1. **First**: `vars_inspect action:list` — see what ViewModels are tracked
2. **Then**: `vars_inspect action:dump class:MyViewModel` — see all @Published property values
3. **If needed**: `vars_inspect action:mirror class:MyViewModel` — full property dump including private state
4. **To test a theory**: `vars_inspect action:set path:MyViewModel.myFlag value:true` — mutate and observe

**Do NOT add print/NSLog statements to debug state.** You have live runtime inspection — use it. Adding logs requires a rebuild + redeploy cycle. `vars_inspect` gives you the answer immediately.

Only add logging when you need to trace **when** something happens (call order, timing), not **what** the current value is.

## Controlling app state without UI

When you need to change app behavior without tapping through UI:

1. **`defaults`** — set UserDefaults keys. Apps often read debug flags, feature toggles, onboarding state from UserDefaults. `defaults action=set key="DEBUG_ZOOM" value=14.0` then trigger a re-read.
2. **`vars_inspect action=set`** — mutate a @Published property directly. Triggers SwiftUI view updates.
3. **`flags`** — override feature flags. Requires `deploy` to take effect.
4. **`keychain`** — modify stored auth tokens or credentials.

## Checking if real data is flowing — use `network` BEFORE adding logs

When you need to know if the app is making API calls, getting responses, or loading real data:

1. `network action:start` — start capturing HTTP traffic
2. Trigger the action (navigate, tap, etc.)
3. `network action:log` — see all requests/responses with URLs, status codes, bodies
4. `network action:log filter:"graphql"` — filter to specific endpoints

**Do NOT add print statements to check if data is loading.** The network tool captures every HTTP request the app makes — URLs, headers, response codes, response bodies. Use it.

## Building

For simulator builds, use Pepper MCP tools:
- `mcp__pepper__iterate` — build + deploy + verify (recommended)
- `mcp__pepper__build` — build only
- `mcp__pepper__deploy` — relaunch without rebuilding

For device builds:
- `mcp__pepper__build_device` — build + install + launch on physical device

Never call raw `xcodebuild` or `simctl` — they are blocked by hooks.
The MCP tools use the worktree-aware wrapper automatically.

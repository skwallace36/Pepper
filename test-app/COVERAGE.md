# Test App Coverage

Command-by-command status of Pepper running against `PepperTestApp` (`com.pepper.testapp`).

Status: `pass` | `fail` | `crash` | `partial` | `untested`

Last run: 2026-03-21

## Meta

| Command | Status | Notes |
|---------|--------|-------|
| `ping` | pass | Health check — confirmed working during setup |
| `help` | untested | |
| `status` | untested | |
| `timeline` (query) | untested | Flight recorder — query recorded events |
| `timeline` (status) | untested | |
| `timeline` (config) | untested | |
| `timeline` (clear) | untested | |

## Navigation

| Command | Status | Notes |
|---------|--------|-------|
| `navigate` (tab) | pass | Tab switching works via tap text |
| `navigate` (deeplink) | untested | No deep links registered in generic mode |
| `back` | fail | Pops once from 3-deep SwiftUI NavigationStack, then reports "already at root" while still on Detail screen. Nav stack depth detection broken for SwiftUI. |
| `dismiss` | untested | Sheet present/dismiss not yet tested |
| `screen` | pass | Reports tab name and screen type |
| `deeplinks` | untested | List available deep link destinations |

## Interaction

| Command | Status | Notes |
|---------|--------|-------|
| `tap` (text) | pass | "Tap Me", "Start 3s Timer", tab bar items all work |
| `tap` (element) | untested | A11y identifiers present but not tested via element param |
| `tap` (point) | untested | |
| `tap` (tab) | untested | Programmatic tab selection not tested |
| `tap` (duration/long press) | untested | "Hold Me" button exists |
| `input` | untested | Text field and text editor exist with a11y IDs |
| `toggle` | untested | Toggle switches exist with a11y IDs |
| `scroll` (direction) | pass | Scrolls list, reveals more items |
| `scroll` (element) | untested | |
| `scroll_to` | untested | |
| `swipe` (left/right) | untested | List rows have swipe actions |
| `gesture` (pinch) | untested | Zoomable image exists |
| `gesture` (rotate) | untested | |
| `dismiss_keyboard` | untested | |
| `dialog` (list) | untested | Alert dialog exists behind "Show Alert" button |
| `dialog` (current) | untested | |
| `dialog` (dismiss) | untested | |
| `dialog` (share_sheet) | untested | |
| `dialog` (dismiss_sheet) | untested | |
| `dialog` (auto_dismiss) | untested | |

## Observation

| Command | Status | Notes |
|---------|--------|-------|
| `look` | pass | Sees all controls, text, tab bar. Compact output is good. |
| `tree` | untested | |
| `read` | untested | Elements have a11y IDs for targeted reads |
| `introspect` (full) | untested | |
| `introspect` (accessibility) | untested | |
| `introspect` (text) | untested | |
| `introspect` (tappable) | untested | |
| `introspect` (interactive) | untested | |
| `introspect` (mirror) | untested | |
| `introspect` (platform) | untested | |
| `introspect` (map) | untested | |
| `introspect` (content_area) | untested | |
| `find` (count) | untested | |
| `find` (first) | untested | |
| `find` (list) | untested | |
| `identify_icons` | untested | 4 SF Symbol icon-only buttons exist |
| `identify_selected` | untested | Segmented control exists |
| `highlight` | untested | |

## Inspection

| Command | Status | Notes |
|---------|--------|-------|
| `vars` (list) | fail | Returns empty — `@Observable` not detected. Pepper looks for `@Published`/ObservableObject. |
| `vars` (get) | untested | Blocked by list returning empty |
| `vars` (set) | untested | Blocked by list returning empty |
| `vars` (discover) | untested | |
| `vars` (dump) | untested | |
| `vars` (mirror) | untested | |
| `heap` (find) | pass | Finds `PepperTestApp.AppState` and all KeyPaths |
| `heap` (inspect) | untested | |
| `heap` (read) | untested | |
| `heap` (classes) | untested | |
| `heap` (controllers) | untested | |
| `heap_snapshot` (snapshot) | untested | |
| `heap_snapshot` (diff) | untested | |
| `heap_snapshot` (clear) | untested | |
| `heap_snapshot` (status) | untested | |
| `layers` | crash | App crashes when `layers` targets gradient area. Needs investigation. |
| `console` (start) | pass | Logging capture starts successfully |
| `console` (stop) | untested | |
| `console` (status) | untested | |
| `console` (log/read) | untested | App crashed before we could read after tap |
| `console` (clear) | untested | |
| `network` (start) | untested | "Fetch HTTP" button exists, hits httpbin.org |
| `network` (stop) | untested | |
| `network` (status) | untested | |
| `network` (log) | untested | |
| `network` (clear) | untested | |
| `animations` (scan) | untested | Pulsing dot and spinner are running |
| `animations` (trace) | untested | |
| `animations` (speed) | untested | |
| `hook` (install) | untested | |
| `hook` (remove) | untested | |
| `hook` (remove_all) | untested | |
| `hook` (list) | untested | |
| `hook` (log) | untested | |
| `hook` (clear) | untested | |
| `flags` | untested | Feature flag queries |

## Toolbox

| Command | Status | Notes |
|---------|--------|-------|
| `lifecycle` (background) | untested | |
| `lifecycle` (foreground) | untested | |
| `lifecycle` (memory_warning) | untested | |
| `lifecycle` (cycle) | untested | |
| `orientation` (portrait) | untested | |
| `orientation` (landscape) | untested | |
| `push` | untested | Inject push notification payloads |
| `clipboard` (get) | untested | |
| `clipboard` (set) | untested | |
| `clipboard` (clear) | untested | |
| `defaults` (list) | untested | |
| `defaults` (get) | untested | |
| `defaults` (set) | untested | |
| `defaults` (delete) | untested | |
| `keychain` (list) | untested | |
| `keychain` (get) | untested | |
| `keychain` (set) | untested | |
| `keychain` (delete) | untested | |
| `keychain` (clear) | untested | |
| `cookies` (list) | untested | WKWebView exists for cookie testing |
| `cookies` (get) | untested | |
| `cookies` (delete) | untested | |
| `cookies` (clear) | untested | |
| `locale` (current) | untested | |
| `locale` (set) | untested | |
| `locale` (reset) | untested | |
| `locale` (lookup) | untested | |
| `locale` (languages) | untested | |
| `memory` (snapshot) | untested | |
| `memory` (vm) | untested | |

## Flow Control

| Command | Status | Notes |
|---------|--------|-------|
| `wait_for` (visible) | untested | Timer exists (3s countdown, state changes to "FIRED") |
| `wait_for` (exists) | untested | |
| `wait_for` (has_value) | untested | |
| `wait_idle` | untested | |
| `batch` | untested | |
| `watch` | untested | |
| `unwatch` | untested | |
| `subscribe` | untested | Event type subscriptions |
| `unsubscribe` | untested | |
| `test` (start) | untested | Test lifecycle events |
| `test` (result) | untested | |
| `test` (reset) | untested | |
| `record` | untested | Record test command sequences |

## Bugs Found

1. **`back` nav stack detection** — SwiftUI NavigationStack depth not correctly detected. After pushing 3 levels deep, first `back` pops but second reports "already at root" while still on the Detail screen. Pepper likely only checks UINavigationController's viewControllers count, which SwiftUI may not populate the same way.

2. **`layers` crash** — Sending `layers` with a point targeting the gradient area crashes the app. WebSocket connection lost. Needs crash log investigation.

3. **`vars` empty for @Observable** — `vars action:list` returns 0 instances. Pepper's var scanning looks for `@Published` properties on `ObservableObject` subclasses. The test app uses Swift 5.9 `@Observable` macro, which Pepper doesn't support yet.

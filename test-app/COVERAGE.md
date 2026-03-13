# Test App Coverage

Command-by-command status of Pepper running against `PepperTestApp` (`com.pepper.testapp`).

Status: `pass` | `fail` | `crash` | `partial` | `untested`

Last run: 2026-03-21

## Navigation

| Command | Status | Notes |
|---------|--------|-------|
| `navigate` (tab) | pass | Tab switching works via tap text |
| `navigate` (deeplink) | untested | No deep links registered in generic mode |
| `back` | fail | Pops once from 3-deep SwiftUI NavigationStack, then reports "already at root" while still on Detail screen. Nav stack depth detection broken for SwiftUI. |
| `dismiss` | untested | Sheet present/dismiss not yet tested |
| `screen` | pass | Reports tab name and screen type |

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
| `swipe` | untested | List rows have swipe actions |
| `gesture` (pinch) | untested | Zoomable image exists |
| `dismiss_keyboard` | untested | |
| `dialog` | untested | Alert dialog exists behind "Show Alert" button |

## Observation

| Command | Status | Notes |
|---------|--------|-------|
| `look` | pass | Sees all controls, text, tab bar. Compact output is good. |
| `tree` | untested | |
| `read` | untested | Elements have a11y IDs for targeted reads |
| `introspect` | untested | |
| `find` | untested | |
| `identify_icons` | untested | 4 SF Symbol icon-only buttons exist |
| `identify_selected` | untested | Segmented control exists |
| `highlight` | untested | |

## Inspection

| Command | Status | Notes |
|---------|--------|-------|
| `vars` | fail | Returns empty — `@Observable` not detected. Pepper looks for `@Published`/ObservableObject. Need to support Observation framework. |
| `heap` | pass | Finds `PepperTestApp.AppState` and all KeyPaths |
| `layers` | crash | App crashes when `layers` command targets gradient area. Needs investigation. |
| `console` | partial | `start` works, `read` untested (app crashed before we could read after tap) |
| `network` | untested | "Fetch HTTP" button exists, hits httpbin.org |
| `animations` | untested | Pulsing dot and spinner are running |
| `hook` | untested | |

## Toolbox

| Command | Status | Notes |
|---------|--------|-------|
| `lifecycle` | untested | |
| `orientation` | untested | |
| `push` | untested | |
| `clipboard` | untested | |
| `defaults` | untested | |
| `keychain` | untested | |
| `locale` | untested | |
| `memory` | untested | |

## Flow Control

| Command | Status | Notes |
|---------|--------|-------|
| `wait_for` | untested | Timer exists (3s countdown, state changes to "FIRED") |
| `wait_idle` | untested | |
| `batch` | untested | |
| `watch`/`unwatch` | untested | |

## Bugs Found

1. **`back` nav stack detection** — SwiftUI NavigationStack depth not correctly detected. After pushing 3 levels deep, first `back` pops but second reports "already at root" while still on the Detail screen. Pepper likely only checks UINavigationController's viewControllers count, which SwiftUI may not populate the same way.

2. **`layers` crash** — Sending `layers` with a point targeting the gradient area crashes the app. WebSocket connection lost. Needs crash log investigation.

3. **`vars` empty for @Observable** — `vars action:list` returns 0 instances. Pepper's var scanning looks for `@Published` properties on `ObservableObject` subclasses. The test app uses Swift 5.9 `@Observable` macro, which Pepper doesn't support yet.

# pepper Command Reference

All commands are sent as JSON over WebSocket to `ws://localhost:8765`.

**CLI tool:** `tools/pepper-ctl` wraps all commands. Run `pepper-ctl --help` for usage.

## Command Summary

| Command | Category | Description | CLI shortcut |
|---------|----------|-------------|-------------|
| `ping` | meta | Health check | `pepper-ctl ping` |
| `help` | meta | List available commands | `pepper-ctl help` |
| `status` | meta | Server connection info | `pepper-ctl raw '{"cmd":"status"}'` |
| `navigate` | navigation | Navigate via deep link, tab, or screen ID | `pepper-ctl navigate --deeplink home` |
| `back` | navigation | Pop nav stack or dismiss modal | `pepper-ctl back` |
| `dismiss` | navigation | Dismiss topmost presented sheet/modal | `pepper-ctl raw '{"cmd":"dismiss"}'` |
| `screen` | navigation | Get current screen info | `pepper-ctl screen` |
| `deeplinks` | navigation | List available deep link destinations | `pepper-ctl raw '{"cmd":"deeplinks"}'` |
| `tap` | interaction | Tap an element | `pepper-ctl tap --id btn` / `--text "Label"` |
| `input` | interaction | Set text field value | `pepper-ctl input --id field --value "text"` |
| `toggle` | interaction | Toggle switch / cycle segment | `pepper-ctl toggle --id switch_id` |
| `swipe` | interaction | Swipe/drag gesture via touch synthesis | `pepper-ctl raw '{"cmd":"swipe",...}'` |
| `scroll` | interaction | Scroll by direction or to element | `pepper-ctl scroll --direction down` |
| `gesture` | interaction | Multi-touch gestures (pinch, rotate) | `pepper-ctl raw '{"cmd":"gesture","params":{"type":"pinch"}}'` |
| `tree` | observation | Full view hierarchy | `pepper-ctl tree --depth 3` |
| `read` | observation | Read single element details | `pepper-ctl read --id element_id` |
| `look` | observation | Compact screen summary with tap commands | `pepper-ctl look` |
| `heap` | inspection | Discover live objects, controllers, classes | `pepper-ctl raw '{"cmd":"heap","params":{"action":"classes","pattern":"Manager"}}'` |
| `introspect` | observation | Deep SwiftUI introspection | `pepper-ctl raw '{"cmd":"introspect"}'` |
| `wait_for` | flow control | Poll until condition met | `pepper-ctl raw '{"cmd":"wait_for",...}'` |
| `batch` | flow control | Execute commands in sequence | `pepper-ctl batch -f commands.json` |
| `watch` | automation | Watch for element changes | `pepper-ctl raw '{"cmd":"watch",...}'` |
| `unwatch` | automation | Stop watches | `pepper-ctl raw '{"cmd":"unwatch",...}'` |
| `subscribe` | events | Subscribe to event types | `pepper-ctl wait event_name` |
| `unsubscribe` | events | Remove event subscriptions | `pepper-ctl raw '{"cmd":"unsubscribe",...}'` |
| `dismiss_keyboard` | interaction | Resign first responder to dismiss keyboard | `pepper-ctl raw '{"cmd":"dismiss_keyboard"}'` |
| `scroll_to` | interaction | Scroll incrementally until target text appears | `pepper-ctl raw '{"cmd":"scroll_to","params":{"text":"Safe Zone"}}'` |
| `highlight` | observation | Draw colored border around element for debugging | `pepper-ctl raw '{"cmd":"highlight","params":{"text":"Casey","color":"green"}}'` |
| `identify_icons` | observation | Scan unlabeled buttons and match against icon catalog | `pepper-ctl raw '{"cmd":"identify_icons"}'` |
| `identify_selected` | observation | Detect visually selected item among siblings | `pepper-ctl raw '{"cmd":"identify_selected","params":{"labels":["Day","Week"]}}'` |
| `wait_idle` | flow control | Wait for app to become idle (no animations/transitions) | `pepper-ctl raw '{"cmd":"wait_idle","params":{"timeout_ms":3000}}'` |
| `dialog` | interaction | Query/dismiss system dialogs and share sheets | `pepper-ctl raw '{"cmd":"dialog","params":{"action":"list"}}'` |
| `test` | automation | Test lifecycle events (start/result/reset) | `pepper-ctl raw '{"cmd":"test","params":{"action":"start","test_id":"DL-01"}}'` |
| `memory` | toolbox | Process memory stats (footprint, VM info) | `pepper-ctl raw '{"cmd":"memory"}'` |
| `lifecycle` | toolbox | Simulate background/foreground cycle, memory warnings | `pepper-ctl raw '{"cmd":"lifecycle","params":{"action":"cycle"}}'` |
| `orientation` | toolbox | Force device orientation | `pepper-ctl raw '{"cmd":"orientation","params":{"value":"landscape_left"}}'` |
| `push` | toolbox | Inject push notification payloads | `pepper-ctl raw '{"cmd":"push","params":{"title":"Test","body":"Hello"}}'` |
| `locale` | toolbox | Override locale/language, lookup localization keys | `pepper-ctl raw '{"cmd":"locale","params":{"action":"set","language":"es"}}'` |
| `network` | network | HTTP traffic interception | `pepper-ctl raw '{"cmd":"network","params":{"action":"start"}}'` |
| `vars` | inspection | Runtime variable inspection & mutation (@Published + all properties) | `pepper-ctl raw '{"cmd":"vars","params":{"action":"list"}}'` |
| `layers` | inspection | Deep CALayer tree inspection at a point (colors, gradients, shadows) | `pepper-ctl raw '{"cmd":"layers","params":{"point":"200,400"}}'` |
| `console` | inspection | App stderr/NSLog capture and query | `pepper-ctl raw '{"cmd":"console","params":{"action":"start"}}'` |
| `animations` | inspection | Scan active CAAnimations or trace view movement over time | `pepper-ctl raw '{"cmd":"animations"}'` |
| `find` | observation | Query elements using NSPredicate expressions | `pepper-ctl raw '{"cmd":"find","params":{"predicate":"label CONTAINS \'Save\'"}}'` |
| `hook` | inspection | Hook ObjC methods at runtime to log invocations | `pepper-ctl raw '{"cmd":"hook","params":{"action":"install","class":"UIViewController","method":"viewDidAppear:"}}'` |
| `heap_snapshot` | inspection | Heap snapshots and diffing | `pepper-ctl raw '{"cmd":"heap_snapshot","params":{"action":"snapshot"}}'` |
| `defaults` | toolbox | NSUserDefaults access | `pepper-ctl raw '{"cmd":"defaults","params":{"action":"list"}}'` |
| `clipboard` | toolbox | Clipboard access (get/set/clear) | `pepper-ctl raw '{"cmd":"clipboard","params":{"action":"get"}}'` |
| `cookies` | toolbox | Web cookie access | `pepper-ctl raw '{"cmd":"cookies","params":{"action":"list"}}'` |
| `keychain` | toolbox | Keychain access | `pepper-ctl raw '{"cmd":"keychain","params":{"action":"list"}}'` |
| `timeline` | meta | Flight recorder queries | `pepper-ctl raw '{"cmd":"timeline","params":{"action":"query"}}'` |

## Message Format

### Request

```json
{
  "id": "abc123",
  "cmd": "command_name",
  "params": { ... }
}
```

- `id` (string, required): Unique identifier for correlating responses.
- `cmd` (string, required): Command name.
- `params` (object, optional): Command-specific parameters.

### Response

```json
{
  "id": "abc123",
  "status": "ok",
  "data": { ... }
}
```

- `status`: `"ok"` or `"error"`.
- `data`: Command-specific response data. On error, contains `{"message": "..."}`.

### Event (server-pushed)

```json
{
  "event": "event_name",
  "data": { ... }
}
```

---

## Navigation

### navigate

Navigate to a screen using deep links, tab index, or screen ID.

| Param | Type | Required | Description |
|-------|------|----------|-------------|
| `deeplink` | string | one of four | Deep link path (preferred). See `deeplinks` command for available paths. |
| `deeplink_params` | object | no | Query parameters for the deep link (e.g. `{"petId": "123"}`). |
| `tab` | int | one of four | Tab index to switch to. |
| `to` | string | one of four | Registered screen ID to navigate to. |
| `action` | string | one of four | `"pop"` (pop nav stack) or `"dismiss"` (dismiss modal). Works even when the back button is hidden. |

Exactly one of `deeplink`, `tab`, `to`, or `action` must be provided.

**Deep link navigation (preferred):**
```json
{"id": "1", "cmd": "navigate", "params": {"deeplink": "home"}}
```

```json
{"id": "2", "cmd": "navigate", "params": {"deeplink": "activity", "deeplink_params": {"petId": "123", "tab": "week"}}}
```

Response:
```json
{
  "id": "1",
  "status": "ok",
  "data": {
    "deeplink": "home",
    "deeplink_url": "fi://home",
    "current_screen": "HomeViewController",
    "type": "HomeViewController",
    "title": "",
    "selected_tab": 0,
    "note": "Deep link navigation is async. Use 'wait_for' then 'screen' to confirm navigation completed."
  }
}
```

**Tab switching:**
```json
{"id": "3", "cmd": "navigate", "params": {"tab": 2}}
```

**Screen ID navigation:**
```json
{"id": "4", "cmd": "navigate", "params": {"to": "settings"}}
```

**Pop/dismiss (direct nav stack control):**
```json
{"id": "5", "cmd": "navigate", "params": {"action": "pop"}}
```
Calls `popViewController(animated:)` directly — works even when the back button is hidden or obscured by SwiftUI overlays. Use `"dismiss"` to dismiss a modal instead.

### back

Go back by popping the navigation stack or dismissing a modal. No params required.

```json
{"id": "1", "cmd": "back"}
```

Response (pop):
```json
{
  "id": "1",
  "status": "ok",
  "data": {
    "action": "pop",
    "popped_screen": "SettingsViewController",
    "current_screen": "HomeViewController"
  }
}
```

Response (dismiss modal):
```json
{
  "id": "1",
  "status": "ok",
  "data": {
    "action": "dismiss",
    "dismissed_screen": "ModalViewController",
    "current_screen": "HomeViewController"
  }
}
```

Errors:
- `"Cannot go back: already at root screen"`

### dismiss

Dismiss the topmost presented sheet/modal. Safer than `back` because it:
- ONLY dismisses presented view controllers, never pops navigation stacks
- Will NOT dismiss the home view (first-level presented VC)
- Only works when there are 2+ levels of presentation (a sheet on top of the home view)

```json
{"id": "1", "cmd": "dismiss"}
```

Response:
```json
{
  "id": "1",
  "status": "ok",
  "data": {
    "action": "dismiss",
    "dismissed_screen": "fi_hosting_controller<...>"
  }
}
```

Errors:
- `"Nothing to dismiss — only the home view is presented"`
- `"No root view controller"`

### screen

Get information about the currently visible screen. No params.

```json
{"id": "1", "cmd": "screen"}
```

Response:
```json
{
  "id": "1",
  "status": "ok",
  "data": {
    "screen_id": "SettingsViewController",
    "type": "SettingsViewController",
    "title": "Settings",
    "navigation_stack": ["HomeViewController", "SettingsViewController"],
    "can_go_back": true,
    "tab_index": 0,
    "tab_count": 5,
    "is_modal": false
  }
}
```

### deeplinks

List all available deep link destinations. This is a discovery command -- use `navigate` to actually navigate.

| Param | Type | Required | Description |
|-------|------|----------|-------------|
| `category` | string | no | Filter by category: `"navigation"`, `"content"`, `"settings"`, `"feature"`, `"system"` |

```json
{"id": "1", "cmd": "deeplinks"}
```

```json
{"id": "2", "cmd": "deeplinks", "params": {"category": "navigation"}}
```

Response:
```json
{
  "id": "1",
  "status": "ok",
  "data": {
    "count": 42,
    "categories": ["content", "feature", "navigation", "settings", "system"],
    "usage": "Use {\"cmd\": \"navigate\", \"params\": {\"deeplink\": \"<path>\", \"deeplink_params\": {\"key\": \"value\"}}} to navigate",
    "deeplinks": [
      {
        "path": "home",
        "category": "navigation",
        "description": "Switch to home/live tab",
        "url": "fi://home",
        "params": [
          {"name": "petId", "required": false, "description": "Pet ID to switch to"}
        ]
      }
    ]
  }
}
```

---

## Interaction

### tap

Tap an element via IOHIDEvent synthesis. Single mechanism — works for both UIKit and SwiftUI.

| Param | Type | Required | Description |
|-------|------|----------|-------------|
| `element` | string | one of five | Accessibility identifier of the element. |
| `text` | string | one of five | Visible text or accessibility label to find. Works on SwiftUI buttons. |
| `exact` | bool | no | When using `text`, require exact match (default: `true`). Set `false` for substring match. |
| `class` | string | one of five | UIKit class name (e.g. `"UIButton"`). Use with `index`. |
| `index` | int | no | Index when using `class` strategy (default: 0). |
| `tab` | int | one of five | Tab bar index to select (programmatic, no touch). |
| `point` | object | one of five | Screen coordinates `{"x": 100, "y": 750}` for coordinate-based tap. |
| `duration` | number | no | Hold duration in seconds (default: 0.05). Use longer for hold-to-activate buttons. |

Exactly one element selector must be provided: `element`, `text`, `class`, `tab`, or `point`.

**By visible text (works on UIKit and SwiftUI):**
```json
{"cmd": "tap", "params": {"text": "Sound"}}
```

**By accessibility ID:**
```json
{"cmd": "tap", "params": {"element": "save_button"}}
```

**By screen coordinate:**
```json
{"cmd": "tap", "params": {"point": {"x": 100, "y": 750}}}
```

**With hold duration (for hold-to-activate buttons):**
```json
{"cmd": "tap", "params": {"text": "Sound", "duration": 1.0}}
```

**By tab index (programmatic selection):**
```json
{"cmd": "tap", "params": {"tab": 0}}
```

Response:
```json
{
  "status": "ok",
  "data": {
    "strategy": "accessibility_label",
    "description": "Sound",
    "type": "hid_touch",
    "tap_point": {"x": 119, "y": 430}
  }
}
```

The `strategy` field indicates which resolution method found the element (`text`, `accessibility_label`, `accessibility_id`, `class`, `point`, `tab_index`). The `type` is always `hid_touch` (IOHIDEvent injection) except for tab selection which is `tab` (programmatic).

Errors:
- `"No key window available"`
- `"Element not found by text: ..."` — no element matching the selector
- `"HID tap synthesis failed"` — IOHIDEvent injection failed (dlsym issue)
- `"Element found but not tappable: <desc>"` -- element exists but has no tap handler

### input

Set text on a text input field (UITextField, UITextView, or UISearchBar). Fires change notifications so delegates and bindings update.

| Param | Type | Required | Description |
|-------|------|----------|-------------|
| `element` | string | no* | Accessibility identifier of the text input. |
| `text` | string | no* | Visible text/placeholder to find the input. |
| `class` | string | no* | UIKit class name (e.g. `"UITextField"`). Use with `index`. |
| `point` | object | no* | Screen coordinates `{"x": 100, "y": 300}`. |
| `value` | string | **yes** | Text value to set. |
| `clear` | bool | no | Clear existing text before typing (default: `true`). |
| `submit` | bool | no | Simulate pressing the return/search key after input (default: `false`). |

*If no element selector is provided, the command targets the currently focused text field (first responder).

**By accessibility ID:**
```json
{"id": "1", "cmd": "input", "params": {"element": "email_field", "value": "user@example.com"}}
```

**Target focused field (no selector):**
```json
{"id": "2", "cmd": "input", "params": {"value": "hello world"}}
```

**With submit:**
```json
{"id": "3", "cmd": "input", "params": {"element": "search_bar", "value": "golden retriever", "submit": true}}
```

**Append without clearing:**
```json
{"id": "4", "cmd": "input", "params": {"element": "notes_field", "value": " additional text", "clear": false}}
```

Response:
```json
{
  "id": "1",
  "status": "ok",
  "data": {
    "strategy": "accessibility_id",
    "description": "email_field",
    "type": "textField",
    "value": "user@example.com",
    "placeholder": "Enter email"
  }
}
```

The `type` field will be `"textField"`, `"textView"`, or `"searchBar"`.

Errors:
- `"Missing required param: value"`
- `"No element selector and no focused text field"`
- `"Element not found"`
- `"Element is not a text input: <desc>"`

### toggle

Toggle a UISwitch or cycle a UISegmentedControl.

| Param | Type | Required | Description |
|-------|------|----------|-------------|
| `element` | string | **yes** | Accessibility identifier. |
| `value` | bool/int | no | Explicit value. For switches: `true`/`false`. For segmented controls: segment index. Omit to toggle/cycle to next. |

**Toggle a switch:**
```json
{"id": "1", "cmd": "toggle", "params": {"element": "notifications_switch"}}
```

**Set switch to specific value:**
```json
{"id": "2", "cmd": "toggle", "params": {"element": "notifications_switch", "value": true}}
```

**Cycle segmented control:**
```json
{"id": "3", "cmd": "toggle", "params": {"element": "sort_control"}}
```

**Set specific segment:**
```json
{"id": "4", "cmd": "toggle", "params": {"element": "sort_control", "value": 2}}
```

Response (switch):
```json
{
  "id": "1",
  "status": "ok",
  "data": {
    "element": "notifications_switch",
    "type": "switch",
    "value": true
  }
}
```

Response (segmented control):
```json
{
  "id": "3",
  "status": "ok",
  "data": {
    "element": "sort_control",
    "type": "segmentedControl",
    "value": 2
  }
}
```

Errors:
- `"Missing required param: element"`
- `"Element not found: <id>"`
- `"Element is not toggleable: <id>"`
- `"Segment index out of range: <index>"`

### scroll

Scroll a scroll view. Two modes: scroll to make an element visible (programmatic), or scroll by direction and amount (touch synthesis — real finger drag).

**Mode 1: Scroll to element**

| Param | Type | Required | Description |
|-------|------|----------|-------------|
| `element` | string | **yes** | Accessibility identifier to scroll into view. |

```json
{"id": "1", "cmd": "scroll", "params": {"element": "bottom_section"}}
```

Response:
```json
{
  "id": "1",
  "status": "ok",
  "data": {
    "element": "bottom_section",
    "scrollOffset": {"x": 0, "y": 450}
  }
}
```

**Mode 2: Scroll by direction**

| Param | Type | Required | Description |
|-------|------|----------|-------------|
| `direction` | string | **yes** | `"up"`, `"down"`, `"left"`, or `"right"`. |
| `amount` | number | no | Points to scroll (default: 200). Determines finger travel distance. Alias: `distance`. |
| `duration` | number | no | Gesture duration in seconds (default: 0.4). |
| `scrollView` | string | no | Accessibility identifier of a specific scroll view. Centers gesture on it. |
| `from` | object | no | Starting point `{"x": N, "y": N}`. Overrides auto-centering. Also accepts top-level `x`/`y` params as shorthand. |

```json
{"id": "2", "cmd": "scroll", "params": {"direction": "down", "amount": 300}}
```

```json
{"id": "3", "cmd": "scroll", "params": {"direction": "down", "amount": 500, "scrollView": "main_scroll"}}
```

Response:
```json
{
  "id": "2",
  "status": "ok",
  "data": {
    "direction": "down",
    "amount": 300,
    "duration": 0.4,
    "gesture": {"from": {"x": 196, "y": 448}, "to": {"x": 196, "y": 148}}
  }
}
```

> **Note**: Direction-based scroll uses real touch synthesis (finger drag). `"scroll down"` means "see content below" — the finger moves UP on screen. The gesture goes through the full UIKit event pipeline (gesture recognizers, delegates, deceleration). The `scrollView` param centers the gesture on that view rather than targeting it directly.

Errors:
- `"Missing required param: element or direction"`
- `"Element not found: <id>"`
- `"No scroll view ancestor found for: <id>"`
- `"Scroll gesture failed — touch synthesis unavailable"`
- `"Invalid direction: <dir>. Use up/down/left/right"`

### swipe

Perform a swipe/drag gesture using touch event synthesis. Like `scroll` (direction mode), `swipe` generates real touch began/moved/ended events through the UIKit event system. This triggers gesture recognizers, pull-to-refresh, swipe-to-dismiss, and other gesture-driven behaviors.

**Mode 1: Explicit coordinates**

| Param | Type | Required | Description |
|-------|------|----------|-------------|
| `from` | object | **yes** | Start point `{"x": 196, "y": 600}` in iOS point coordinates. |
| `to` | object | **yes** | End point `{"x": 196, "y": 200}` in iOS point coordinates. |
| `duration` | number | no | Swipe duration in seconds (default: 0.3). |

```json
{"id": "1", "cmd": "swipe", "params": {"from": {"x": 196, "y": 600}, "to": {"x": 196, "y": 200}}}
```

```json
{"id": "2", "cmd": "swipe", "params": {"from": {"x": 196, "y": 600}, "to": {"x": 196, "y": 200}, "duration": 0.5}}
```

**Mode 2: Direction-based**

| Param | Type | Required | Description |
|-------|------|----------|-------------|
| `direction` | string | **yes** | `"up"`, `"down"`, `"left"`, or `"right"`. Direction the finger moves. |
| `from` | object | no | Start point (default: screen center). |
| `amount` | number | no | Distance in points (default: 400). Alias: `distance`. |
| `duration` | number | no | Swipe duration in seconds (default: 0.3). |

```json
{"id": "3", "cmd": "swipe", "params": {"direction": "down"}}
```

```json
{"id": "4", "cmd": "swipe", "params": {"direction": "up", "from": {"x": 196, "y": 700}, "amount": 300}}
```

Response:
```json
{
  "id": "1",
  "status": "ok",
  "data": {
    "from": {"x": 196, "y": 600},
    "to": {"x": 196, "y": 200},
    "duration": 0.3
  }
}
```

Errors:
- `"Missing required params: from+to, or direction"`
- `"Invalid direction: <dir>. Use up/down/left/right"`
- `"Swipe failed — touch synthesis unavailable. Check device logs."`

**Notes:**
- `swipe` uses UIKit private API touch synthesis (`PepperTouchSynthesizer`). It works on Simulator debug builds only.
- Direction semantics: `"down"` = finger moves downward (scrolls content up, good for dismissing sheets). `"up"` = finger moves upward (scrolls content down).
- Visual feedback: A red trail line and dot are shown during the swipe via the touch visualizer overlay.
- For scrolling content without gesture recognition, use `scroll` instead (faster, more predictable).

---

## Observation

### tree

Get the full view hierarchy as a recursive tree. Each node includes class name, frame, accessibility ID/label, visibility, and children.

| Param | Type | Required | Description |
|-------|------|----------|-------------|
| `depth` | int | no | Maximum tree depth (default/max: 50). |
| `element` | string | no | Accessibility identifier to scope the tree to a subtree. Omit for full window. |

```json
{"id": "1", "cmd": "tree"}
```

```json
{"id": "2", "cmd": "tree", "params": {"depth": 3}}
```

```json
{"id": "3", "cmd": "tree", "params": {"element": "settings_container"}}
```

Response:
```json
{
  "id": "1",
  "status": "ok",
  "data": {
    "nodeCount": 42,
    "truncated": false,
    "tree": {
      "class": "UIWindow",
      "frame": {"x": 0, "y": 0, "width": 390, "height": 844},
      "hidden": false,
      "alpha": 1.0,
      "userInteraction": true,
      "children": [
        {
          "class": "UIButton",
          "id": "save_button",
          "label": "Save",
          "info": {
            "type": "button",
            "title": "Save",
            "enabled": true
          },
          "frame": {"x": 20, "y": 400, "width": 335, "height": 44},
          "hidden": false,
          "alpha": 1.0,
          "userInteraction": true
        }
      ]
    }
  }
}
```

Interactive elements include an `info` object with type-specific details (button title, text field text/placeholder, switch state, label text).

Limits: max 50 depth, max 2000 nodes. If truncated, `"truncated": true` and leaf nodes include `"childCount"` instead of `"children"`.

### read

Read detailed information about a specific element by accessibility identifier.

| Param | Type | Required | Description |
|-------|------|----------|-------------|
| `element` | string | **yes** | Accessibility identifier. |

```json
{"id": "1", "cmd": "read", "params": {"element": "email_field"}}
```

Response varies by element type. Common fields: `id`, `type`, `visible`, `frame`, `label`.

```json
{
  "id": "1",
  "status": "ok",
  "data": {
    "id": "email_field",
    "type": "textField",
    "value": "user@example.com",
    "placeholder": "Enter email",
    "enabled": true,
    "editing": false,
    "secureEntry": false,
    "visible": true,
    "frame": {"x": 20, "y": 200, "width": 335, "height": 44}
  }
}
```

Type-specific fields:

| Type | Fields |
|------|--------|
| **button** | `value` (title), `enabled`, `selected` |
| **textField** | `value`, `placeholder`, `enabled`, `editing`, `secureEntry` |
| **textView** | `value`, `editable` |
| **switch** | `value` (bool), `enabled` |
| **slider** | `value` (number), `min`, `max`, `enabled` |
| **segmentedControl** | `value` (selected index), `segmentCount`, `segmentTitles`, `enabled` |
| **label** | `value` (text), `numberOfLines` |
| **image** | `hasImage`, `highlighted` |
| **datePicker** | `value` (ISO 8601 string), `enabled` |
| **progressView** | `value` (0.0-1.0) |
| **activityIndicator** | `value` (isAnimating bool) |

Errors:
- `"Missing required param: element"`
- `"Element not found: <id>"`

### introspect

Deep introspection of the current screen, combining accessibility tree traversal, view hierarchy walking, and Mirror-based SwiftUI reflection.

| Param | Type | Required | Description |
|-------|------|----------|-------------|
| `mode` | string | no | Introspection mode (default: `"full"`). |
| `depth` | int | no | Max depth for `"full"` and `"mirror"` modes (default: 20 for full, 6 for mirror). |

**Modes:**

| Mode | Description |
|------|-------------|
| `full` | All approaches combined: accessibility, view hierarchy, and hosting controller analysis. |
| `accessibility` | Accessibility tree only -- labels, values, and traits. |
| `text` | All visible text on screen with positions. |
| `tappable` | All tappable/interactive elements (labeled only, from accessibility tree). |
| `interactive` | **ALL tappable elements (labeled + unlabeled)** with hit-test filtering. Superset of `tappable`. |
| `map` | Structured screen state grouped by Y-band rows. Best for spatial reasoning. |
| `mirror` | Mirror-based SwiftUI type reflection on hosting views. |
| `platform` | Platform view hierarchy analysis. |

**Full introspection (default):**
```json
{"id": "1", "cmd": "introspect"}
```

**Accessibility elements only:**
```json
{"id": "2", "cmd": "introspect", "params": {"mode": "accessibility"}}
```

**Discover all visible text:**
```json
{"id": "3", "cmd": "introspect", "params": {"mode": "text"}}
```

Response (text mode):
```json
{
  "id": "3",
  "status": "ok",
  "data": {
    "count": 15,
    "texts": [
      {
        "text": "Settings",
        "type": "label",
        "frame": {"x": 150, "y": 44, "width": 90, "height": 22}
      }
    ]
  }
}
```

**Discover tappable elements (labeled only):**
```json
{"id": "4", "cmd": "introspect", "params": {"mode": "tappable"}}
```

**Discover ALL interactive elements (labeled + unlabeled):**

Returns a unified list combining accessibility tree and UIView hierarchy discovery.
Unlabeled elements (icon buttons, close X, edit pens, like hearts) that have no accessibility
label are included with a `heuristic` field inferring their purpose.

| Param | Type | Required | Description |
|-------|------|----------|-------------|
| `mode` | string | **yes** | Must be `"interactive"`. |
| `hit_test` | bool | no | Enable hit-test reachability filtering (default: `true`). Elements behind sheets/modals get `hit_reachable: false`. |
| `limit` | int | no | Maximum elements to return (default: 500). |

```json
{"id": "5", "cmd": "introspect", "params": {"mode": "interactive"}}
```

```json
{"id": "6", "cmd": "introspect", "params": {"mode": "interactive", "hit_test": false, "limit": 200}}
```

Response:
```json
{
  "id": "5",
  "status": "ok",
  "data": {
    "elements": [
      {
        "class": "UIButton",
        "label": null,
        "center": {"x": 390, "y": 130},
        "frame": {"x": 370, "y": 110, "width": 40, "height": 40},
        "labeled": false,
        "source": "uiControl",
        "gestures": ["tap"],
        "is_control": true,
        "control_type": "button",
        "hit_reachable": true,
        "heuristic": "icon_button"
      },
      {
        "class": "AccessibilityNode",
        "label": "Settings",
        "center": {"x": 195, "y": 55},
        "frame": {"x": 150, "y": 44, "width": 90, "height": 22},
        "labeled": true,
        "source": "accessibility",
        "gestures": ["tap"],
        "is_control": false,
        "hit_reachable": true,
        "traits": ["button"]
      }
    ],
    "count": 45,
    "labeled_count": 32,
    "unlabeled_count": 13
  }
}
```

Element fields:

| Field | Type | Description |
|-------|------|-------------|
| `class` | string | UIKit class name or accessibility element type. |
| `label` | string? | Accessibility label (null for unlabeled elements). |
| `center` | object | Center point `{x, y}` in screen coordinates — usable directly for `tap point`. |
| `frame` | object | Bounding rect `{x, y, width, height}` in screen coordinates. |
| `labeled` | bool | Whether the element has an accessibility label. |
| `source` | string | How the element was discovered: `"accessibility"`, `"uiControl"`, or `"gestureRecognizer"`. |
| `gestures` | array | Gesture types: `"tap"`, `"longPress"`, `"swipe"`, `"pan"`. |
| `is_control` | bool | Whether the element is a UIControl subclass. |
| `control_type` | string? | Control classification: `"button"`, `"switch"`, `"slider"`, etc. |
| `hit_reachable` | bool | Whether the element is reachable via hit-test (not occluded by sheets/modals). |
| `heuristic` | string? | Inferred purpose for unlabeled elements: `"close_button"`, `"back_button"`, `"icon_button"`, `"edit_button"`, `"like_button"`, `"more_menu"`, `"search_button"`, `"unlabeled_interactive"`. |
| `traits` | array | Accessibility traits (from accessibility-sourced elements). |

**Structured screen map (spatial layout):**

Returns all elements grouped into horizontal Y-band rows, giving a top-to-bottom spatial layout of the screen. Each element includes a ready-to-use `tap_cmd` field.

| Param | Type | Required | Description |
|-------|------|----------|-------------|
| `mode` | string | **yes** | Must be `"map"`. |
| `band` | int | no | Y-band grouping size in points (default: 40). Smaller values = more rows, finer grouping. |

```json
{"id": "7", "cmd": "introspect", "params": {"mode": "map"}}
```

```json
{"id": "8", "cmd": "introspect", "params": {"mode": "map", "band": 20}}
```

Response:
```json
{
  "id": "7",
  "status": "ok",
  "data": {
    "screen": "HomeViewController",
    "screen_size": [430, 932],
    "element_count": 23,
    "rows": [
      {
        "y_range": [40, 80],
        "elements": [
          {
            "label": "Settings",
            "type": "button",
            "center": [390, 55],
            "frame": [370, 44, 40, 22],
            "tap_cmd": "text",
            "hit_reachable": true
          },
          {
            "label": null,
            "type": "button",
            "center": [40, 55],
            "frame": [20, 44, 40, 22],
            "tap_cmd": "point",
            "hit_reachable": true,
            "heuristic": "back_button"
          }
        ]
      },
      {
        "y_range": [400, 440],
        "elements": [
          {
            "label": "Sound",
            "type": "button",
            "center": [119, 430],
            "frame": [80, 410, 78, 40],
            "tap_cmd": "text",
            "hit_reachable": true
          }
        ]
      }
    ],
    "non_interactive": ["Live", "Updated 2m ago", "Battery: 85%"]
  }
}
```

Element fields:

| Field | Type | Description |
|-------|------|-------------|
| `label` | string? | Accessibility label (null for unlabeled elements). |
| `type` | string | Element type (e.g. `"button"`, `"switch"`, `"textField"`). |
| `center` | array | Center point `[x, y]` in screen coordinates. |
| `frame` | array | Bounding rect `[x, y, width, height]` in screen coordinates. |
| `tap_cmd` | string | How to tap: `"text"` if labeled (use `tap text`), `"point"` if unlabeled (use `tap point`). |
| `hit_reachable` | bool | Whether the element is reachable via hit-test. |
| `heuristic` | string? | Inferred purpose for unlabeled elements (same values as `interactive` mode). |

Top-level fields:

| Field | Type | Description |
|-------|------|-------------|
| `screen` | string | Current screen identifier. |
| `screen_size` | array | Screen dimensions `[width, height]` in points. |
| `element_count` | int | Total interactive elements found. |
| `rows` | array | Elements grouped by Y-band, ordered top to bottom. |
| `non_interactive` | array | Labels of non-interactive text elements on screen. |

**Mirror reflection:**
```json
{"id": "5", "cmd": "introspect", "params": {"mode": "mirror", "depth": 4}}
```

**Platform views:**
```json
{"id": "6", "cmd": "introspect", "params": {"mode": "platform"}}
```

Errors:
- `"Unknown introspect mode: <mode>. Use: full, accessibility, text, tappable, interactive, map, mirror, platform"`
- `"No key window available"` (mirror mode)

---

### gesture

Perform multi-touch gestures (pinch, rotate) using two-finger touch event synthesis. Two fingers are placed symmetrically around a center point and moved simultaneously to simulate pinch-to-zoom or rotation gestures.

**Type: pinch**

Two fingers move toward or away from a center point. Use `start_distance > end_distance` for pinch-in (zoom out) and `start_distance < end_distance` for pinch-out (zoom in).

| Param | Type | Required | Description |
|-------|------|----------|-------------|
| `type` | string | **yes** | Must be `"pinch"`. |
| `center` | object | no | Center point `{"x": 200, "y": 400}` (default: screen center). |
| `start_distance` | number | no | Initial distance between fingers in points (default: 200). |
| `end_distance` | number | no | Final distance between fingers in points (default: 50). |
| `duration` | number | no | Gesture duration in seconds (default: 0.5). |

```json
{"id": "1", "cmd": "gesture", "params": {"type": "pinch"}}
```

```json
{"id": "2", "cmd": "gesture", "params": {"type": "pinch", "center": {"x": 200, "y": 400}, "start_distance": 100, "end_distance": 300, "duration": 0.8}}
```

Response:
```json
{
  "id": "1",
  "status": "ok",
  "data": {
    "gesture": "pinch",
    "center": {"x": 201, "y": 437},
    "start_distance": 200,
    "end_distance": 50
  }
}
```

**Type: rotate**

Two fingers rotate around a center point at a fixed radius. Positive angles rotate clockwise.

| Param | Type | Required | Description |
|-------|------|----------|-------------|
| `type` | string | **yes** | Must be `"rotate"`. |
| `center` | object | no | Center point `{"x": 200, "y": 400}` (default: screen center). |
| `angle` | number | no | Rotation angle in degrees, positive = clockwise (default: 90). |
| `radius` | number | no | Distance from center to each finger in points (default: 50). |
| `duration` | number | no | Gesture duration in seconds (default: 0.5). |

```json
{"id": "3", "cmd": "gesture", "params": {"type": "rotate", "angle": 90}}
```

```json
{"id": "4", "cmd": "gesture", "params": {"type": "rotate", "center": {"x": 200, "y": 400}, "angle": -45, "radius": 80, "duration": 1.0}}
```

Response:
```json
{
  "id": "3",
  "status": "ok",
  "data": {
    "gesture": "rotate",
    "center": {"x": 201, "y": 437},
    "angle": 90,
    "radius": 50
  }
}
```

Errors:
- `"Missing required param 'type' (pinch|rotate)"`
- `"Unknown gesture type '<type>'. Use: pinch, rotate"`
- `"No key window available"`

---

## Automation

### wait_for

Poll for a condition to be met. Returns when the condition is satisfied or on timeout.

| Param | Type | Required | Description |
|-------|------|----------|-------------|
| `until` | object | **yes** | Condition to wait for (see below). |
| `timeout_ms` | int | no | Timeout in milliseconds (default: 5000). |

**Condition types:**

| Condition | Params | Description |
|-----------|--------|-------------|
| Element visible | `{"element": "<id>", "state": "visible"}` | Element exists, not hidden, alpha > 0. |
| Element exists | `{"element": "<id>", "state": "exists"}` | Element is in the view hierarchy. |
| Element has value | `{"element": "<id>", "state": "has_value", "value": "<expected>"}` | Element's text/value matches. |
| Screen is | `{"screen": "<screen_id>"}` | Top view controller matches screen ID. |

The `state` field defaults to `"visible"` if omitted.

**Wait for element to be visible:**
```json
{"id": "1", "cmd": "wait_for", "params": {"until": {"element": "save_button", "state": "visible"}}}
```

**Wait for element to exist (even if hidden):**
```json
{"id": "2", "cmd": "wait_for", "params": {"until": {"element": "loading_spinner", "state": "exists"}}}
```

**Wait for element to have a specific value:**
```json
{"id": "3", "cmd": "wait_for", "params": {"until": {"element": "status_label", "state": "has_value", "value": "Done"}}}
```

**Wait for a specific screen:**
```json
{"id": "4", "cmd": "wait_for", "params": {"until": {"screen": "settings"}, "timeout_ms": 10000}}
```

Response (success):
```json
{"id": "1", "status": "ok", "data": {"waited_ms": 350}}
```

Response (timeout):
```json
{"id": "1", "status": "error", "data": {"message": "Timeout after 5000ms"}}
```

Errors:
- `"Missing required param: until"`
- `"Invalid wait condition. Supported: element+state, screen."`

### batch

Execute a sequence of sub-commands synchronously, collecting all responses.

| Param | Type | Required | Description |
|-------|------|----------|-------------|
| `commands` | array | **yes** | Array of command objects (each with `cmd` and optional `params`). |
| `delay_ms` | int | no | Milliseconds to wait between commands (default: 0). |
| `continue_on_error` | bool | no | Continue executing after a command fails (default: `false`). |

```json
{
  "id": "b1",
  "cmd": "batch",
  "params": {
    "commands": [
      {"cmd": "tap", "params": {"element": "login_button"}},
      {"cmd": "wait_for", "params": {"until": {"screen": "login"}}},
      {"cmd": "input", "params": {"element": "email_field", "value": "test@example.com"}},
      {"cmd": "input", "params": {"element": "password_field", "value": "secret123"}},
      {"cmd": "tap", "params": {"element": "submit_button"}}
    ],
    "delay_ms": 100,
    "continue_on_error": false
  }
}
```

Response:
```json
{
  "id": "b1",
  "status": "ok",
  "data": {
    "total": 5,
    "executed": 5,
    "errors": 0,
    "responses": [
      {"index": 0, "id": "b1-0", "cmd": "tap", "status": "ok", "data": {...}},
      {"index": 1, "id": "b1-1", "cmd": "wait_for", "status": "ok", "data": {...}},
      {"index": 2, "id": "b1-2", "cmd": "input", "status": "ok", "data": {...}},
      {"index": 3, "id": "b1-3", "cmd": "input", "status": "ok", "data": {...}},
      {"index": 4, "id": "b1-4", "cmd": "tap", "status": "ok", "data": {...}}
    ]
  }
}
```

If `continue_on_error` is `false` (default), execution stops at the first error. Sub-command IDs are generated as `<batch_id>-<index>`.

Errors:
- `"Missing required param: commands (array)"`

### watch

Register a background watch that polls for element changes and pushes `watch_update` events over WebSocket when changes are detected. Returns immediately with the initial state; subsequent changes arrive as server-pushed events.

| Param | Type | Required | Description |
|-------|------|----------|-------------|
| `label` | string | one of three | Watch for an element by accessibility label. |
| `point` | object | one of three | Watch the element at screen coordinates `{"x": 100, "y": 750}`. |
| `region` | object | one of three | Watch all elements within a rect `{"x": 0, "y": 400, "w": 430, "h": 200}`. |
| `exact` | bool | no | When using `label`, require exact match (default: `true`). |
| `interval_ms` | int | no | Polling interval in milliseconds (default: 200). |
| `timeout_ms` | int | no | Auto-stop after this many milliseconds (default: 30000). |

Exactly one of `label`, `point`, or `region` must be provided.

**Watch by label:**
```json
{"id": "1", "cmd": "watch", "params": {"label": "Battery"}}
```

**Watch by point:**
```json
{"id": "2", "cmd": "watch", "params": {"point": {"x": 200, "y": 430}, "interval_ms": 500}}
```

**Watch a region:**
```json
{"id": "3", "cmd": "watch", "params": {"region": {"x": 0, "y": 400, "w": 430, "h": 200}, "timeout_ms": 60000}}
```

Response (immediate):
```json
{
  "id": "1",
  "status": "ok",
  "data": {
    "watch_id": "w-abc123",
    "initial": {
      "label": "Battery: 85%",
      "frame": {"x": 150, "y": 60, "width": 100, "height": 20},
      "traits": ["staticText"]
    }
  }
}
```

**Change events (server-pushed):**

After registration, changes are pushed as `watch_update` events:

```json
{
  "event": "watch_update",
  "data": {
    "watch_id": "w-abc123",
    "change": "value_changed",
    "previous": {"label": "Battery: 85%"},
    "current": {"label": "Battery: 84%"}
  }
}
```

Change types:

| Change | Description |
|--------|-------------|
| `appeared` | Element was not present, now it is. |
| `disappeared` | Element was present, now it is gone. |
| `moved` | Element's frame changed position. |
| `value_changed` | Element's label or value changed. |
| `trait_changed` | Element's accessibility traits changed. |
| `timeout` | Watch auto-stopped after `timeout_ms`. |

Errors:
- `"Exactly one of label, point, or region is required"`
- `"No element found at point"`
- `"No elements found in region"`

### unwatch

Stop one or all active watches.

| Param | Type | Required | Description |
|-------|------|----------|-------------|
| `watch_id` | string | no | ID of the watch to stop. Omit to stop all watches. |

**Stop a specific watch:**
```json
{"id": "1", "cmd": "unwatch", "params": {"watch_id": "w-abc123"}}
```

**Stop all watches:**
```json
{"id": "2", "cmd": "unwatch"}
```

Response:
```json
{
  "id": "1",
  "status": "ok",
  "data": {
    "stopped": ["w-abc123"]
  }
}
```

Response (stop all):
```json
{
  "id": "2",
  "status": "ok",
  "data": {
    "stopped": ["w-abc123", "w-def456"]
  }
}
```

Errors:
- `"Unknown watch_id: <id>"`

---

## Meta

### ping

Health check. Returns immediately. No params.

```json
{"id": "1", "cmd": "ping"}
```

Response:
```json
{"id": "1", "status": "ok", "data": {"pong": true}}
```

### help

List all registered commands. No params.

```json
{"id": "1", "cmd": "help"}
```

Response:
```json
{
  "id": "1",
  "status": "ok",
  "data": {
    "commands": ["back", "batch", "deeplinks", "dismiss", "help", "input", "introspect", "navigate", "ping", "read", "screen", "scroll", "scroll_to", "subscribe", "swipe", "tap", "toggle", "tree", "unsubscribe", "unwatch", "wait_for", "wait_idle", "watch"]
  }
}
```

### status

Report server status: active connection count and port.

No params.

```json
{"id": "1", "cmd": "status"}
```

Response:
```json
{
  "id": "1",
  "status": "ok",
  "data": {
    "connections": 2,
    "port": 8765
  }
}
```

### subscribe

Subscribe to server-pushed event types. Connections with active subscriptions only receive matching events. Connections with no subscriptions receive all events.

| Param | Type | Required | Description |
|-------|------|----------|-------------|
| `events` | array of strings | **yes** | Event types to subscribe to. |

```json
{"id": "1", "cmd": "subscribe", "params": {"events": ["navigation_change", "screen_appeared"]}}
```

Response:
```json
{"id": "1", "status": "ok", "data": {"subscribed": ["navigation_change", "screen_appeared"]}}
```

Errors:
- `"Missing 'events' parameter (expected array of event type strings)"`
- `"'events' must contain at least one string event type"`

### unsubscribe

Remove event subscriptions.

| Param | Type | Required | Description |
|-------|------|----------|-------------|
| `events` | array of strings | **yes** | Event types to unsubscribe from. |

```json
{"id": "1", "cmd": "unsubscribe", "params": {"events": ["navigation_change"]}}
```

Response:
```json
{"id": "1", "status": "ok", "data": {"unsubscribed": ["navigation_change"]}}
```

---

## Network Traffic Interception

Captures HTTP/HTTPS traffic from all URLSession instances in the app (including Alamofire and custom configurations). Uses URLProtocol + URLSessionConfiguration swizzling. pepper's own WebSocket (NWListener) is not captured.

**Not auto-started** — must be explicitly enabled via `network start`.

### network

| Param | Type | Required | Description |
|-------|------|----------|-------------|
| `action` | string | **yes** | One of: `start`, `stop`, `status`, `log`, `clear`. |

**Actions:**

| Action | Description | Extra Params |
|--------|-------------|--------------|
| `start` | Start intercepting HTTP traffic | `buffer_size?` (int, default 500) |
| `stop` | Stop intercepting | — |
| `status` | Get interception status and buffer info | — |
| `log` | Return recent captured transactions | `limit?` (int, default 50), `filter?` (URL substring) |
| `clear` | Empty the transaction buffer | — |

**Start capturing:**
```json
{"cmd":"network", "params":{"action":"start"}}
```

```json
{"cmd":"network", "params":{"action":"start", "buffer_size":1000}}
```

Response:
```json
{"status":"ok", "data":{"active":true, "buffer_size":500}}
```

**Query captured traffic:**
```json
{"cmd":"network", "params":{"action":"log", "limit":5}}
```

```json
{"cmd":"network", "params":{"action":"log", "filter":"api.example.com"}}
```

Response:
```json
{
  "status": "ok",
  "data": {
    "count": 2,
    "transactions": [
      {
        "id": "uuid",
        "request": {
          "url": "https://api.example.com/v1/data",
          "method": "GET",
          "headers": {"Authorization": "Bearer ..."},
          "body": null,
          "timestamp_ms": 1700000000000,
          "original_body_size": 0
        },
        "response": {
          "status_code": 200,
          "headers": {"Content-Type": "application/json"},
          "body": "{\"pets\":[...]}",
          "content_length": 1234,
          "original_body_size": 1234
        },
        "timing": {
          "start_ms": 1700000000000,
          "end_ms": 1700000000450,
          "duration_ms": 450
        }
      }
    ]
  }
}
```

**Check status:**
```json
{"cmd":"network", "params":{"action":"status"}}
```

Response:
```json
{"status":"ok", "data":{"active":true, "buffer_size":500, "buffer_count":42, "total_recorded":156}}
```

**Stop capturing:**
```json
{"cmd":"network", "params":{"action":"stop"}}
```

**Clear buffer:**
```json
{"cmd":"network", "params":{"action":"clear"}}
```

**Event broadcast:** While active, each completed HTTP request pushes a `network_request` event to all connected WebSocket clients:

```json
{
  "event": "network_request",
  "data": {
    "id": "uuid",
    "request": {"url": "...", "method": "GET", "headers": {}, "timestamp_ms": 123},
    "response": {"status_code": 200, "headers": {}, "body": "...", "content_length": 1234},
    "timing": {"start_ms": 123, "end_ms": 573, "duration_ms": 450}
  }
}
```

**Body handling:**
- Bodies > 256KB are truncated with `body_truncated: true` and `original_body_size` showing the full size.
- Text content types (JSON, XML, form-urlencoded, etc.) are decoded as UTF-8 strings.
- Binary bodies are base64-encoded with `body_encoding: "base64"`.
- Requests using `httpBodyStream` (e.g. file uploads) will show body as null.

Errors:
- `"Missing 'action' param. Available: start, stop, status, log, clear"`
- `"Unknown action '<action>'. Available: start, stop, status, log, clear"`

---

## Events

Events are pushed from the server to connected clients (filtered by subscriptions).

| Event | Description | Data |
|-------|-------------|------|
| `navigation_change` | Screen changed | `{"from": "...", "to": "..."}` |
| `screen_appeared` | A screen appeared | `{"screen": "screen_id"}` |
| `state_changed` | App state changed | `{"key": "...", "value": "..."}` |
| `watch_update` | Watched element changed | `{"watch_id": "...", "change": "...", "previous": {...}, "current": {...}}` |
| `network_request` | HTTP request completed | `{"id": "...", "request": {...}, "response": {...}, "timing": {...}}` |

---

## Quick-Start Workflows

### Navigate to a screen and tap a button

```bash
pepper-ctl navigate --deeplink home
pepper-ctl wait '{"until": {"screen": "home"}, "timeout_ms": 3000}'
pepper-ctl tap save_button
```

### Fill a form

```bash
pepper-ctl input email_field "user@example.com"
pepper-ctl input password_field "secret123"
pepper-ctl tap submit_button
```

### Inspect the current screen

```bash
pepper-ctl snapshot           # Interactive elements only
pepper-ctl tree               # Full view hierarchy
pepper-ctl tree --depth 3     # Shallow view hierarchy
pepper-ctl read email_field   # Single element detail
pepper-ctl introspect         # Deep SwiftUI introspection
pepper-ctl look  # Visual capture
```

### Wait for loading to complete

```bash
pepper-ctl tap refresh_button
pepper-ctl raw '{"cmd":"wait_for","params":{"until":{"element":"loading_spinner","state":"exists"},"timeout_ms":1000}}'
pepper-ctl raw '{"cmd":"wait_for","params":{"until":{"element":"content_list","state":"visible"},"timeout_ms":10000}}'
pepper-ctl snapshot
```

### Batch multiple actions

```bash
pepper-ctl raw '{
  "cmd": "batch",
  "params": {
    "commands": [
      {"cmd": "navigate", "params": {"deeplink": "home"}},
      {"cmd": "wait_for", "params": {"until": {"screen": "home"}, "timeout_ms": 3000}},
      {"cmd": "look"}
    ],
    "delay_ms": 200
  }
}'
```

### Discover available deep links

```bash
pepper-ctl raw '{"cmd": "deeplinks"}'
pepper-ctl raw '{"cmd": "deeplinks", "params": {"category": "settings"}}'
```

---

## Error Responses

All errors follow this format:

```json
{
  "id": "abc123",
  "status": "error",
  "data": {"message": "Human-readable error description"}
}
```

Common errors:
- `"Unknown command: <cmd>"` -- command not registered
- `"Missing required param: <param>"` -- required parameter not provided
- `"Element not found: <id>"` -- no element with that accessibility identifier
- `"No key window available"` -- app window not ready
- `"Element not interactable: <id>"` -- element hidden or disabled
- `"No root view controller available"` -- app not fully initialized
- `"Timeout after <ms>ms"` -- wait condition not met within timeout

---

## Practical Tips (Getting Commands Right on the First Try)

These are hard-won lessons from real testing sessions. Read these before automating anything.

### App Identity

- **Bundle ID:** Configured per adapter (see `adapter_config().bundle_id`). Override via `BUNDLE_ID` env var.
- **Simulator ID:** Use `xcrun simctl list devices booted` — varies by device
- **Tested devices:** iPhone 16 Pro Max (440x956pt), iPhone Air (420x912pt)

### tap

- **All taps use IOHIDEvent synthesis.** One mechanism for UIKit and SwiftUI — no fallback chains.
- **`text` matches ANY visible text, not just buttons.** Use `introspect mode:accessibility` to see all elements and their frames, then use `point` for disambiguation if needed.
- **SwiftUI buttons are discovered via accessibility tree.** `tap text:"Sound"` resolves the element's accessibility frame and taps its center via HID injection.
- **Hold-to-activate buttons** need `duration` param: `{"cmd":"tap","params":{"text":"Sound","duration":1.0}}`. Default hold is 50ms.
- **Discover before tapping.** `introspect mode:accessibility` shows all elements with labels, traits, and frames.

### input

- **Always use `class: UITextField` (or UITextView) to target input fields.** The `text` strategy searches for visible labels, not input placeholders. `element` searches by accessibility ID, which SwiftUI fields often lack.
- **`clear: true` is the default** and uses select-all + deleteBackward + insertText. This properly updates SwiftUI bindings.
- **Special characters in values (e.g. `!` in passwords):** The `!` character causes shell JSON parsing errors even in single quotes. Use python to bypass:
  ```bash
  python3 -c "
  import subprocess, json
  cmd = json.dumps({'cmd':'input','params':{'class':'UITextField','index':0,'value':'Pepper!12345'}})
  result = subprocess.run(['./tools/pepper-ctl','raw',cmd], capture_output=True, text=True)
  print(result.stdout or result.stderr)
  "
  ```
- **If no selector is given,** the command targets the first responder (focused field). Tap the field first with `point` to focus it, then `input` with just `value`.
- **To replace existing text in a SwiftUI field,** restart the app if the binding fights back. In practice, entering text into an empty field works reliably; overwriting existing text in SwiftUI fields can fail silently because the binding resets the value.

### introspect

- **Use `mode: accessibility` for element discovery.** Returns labels, traits (button, staticText, etc.), frames, and interactive status. This is the go-to for understanding what's on screen.
- **Use `mode: map` for spatial layout.** Groups elements by Y-band rows, top to bottom. Each element has a `tap_cmd` field telling you whether to use `tap text` or `tap point`. Best for understanding the screen layout at a glance.
- **Use `mode: tappable` to find what you can tap.**
- **Use `mode: text` to find all visible text.**
- **`mode: full` can timeout on complex screens.** Start with a specific mode.

### look

- `pepper-ctl look` shows a compact spatial summary of what's on screen — all interactive elements with tap commands, plus visible text.
- **Raw JSON:** `pepper-ctl --json look` for full data with coordinates, frames, scroll context.
- **MCP:** `look()` tool when MCP is configured.

### navigate

- **Deep links are the most reliable navigation method.** Use `pepper-ctl raw '{"cmd":"deeplinks"}'` to discover available paths.
- **Tab switching:** `{"cmd":"navigate","params":{"tab":4}}` switches to Health tab (0=Live, 1=Rank, 2=Profile, 3=Community, 4=Health). **Tab order varies by build — always verify with `screen` first.**

### Login Flow (complete reference)

This is the full sequence to log in from a fresh app launch. See `docs/TESTED-PATTERNS.md` for
verified coordinates and detailed notes per screen.

> **GOTCHA:** On the splash screen, "Continue" opens the environment selector, NOT the login
> flow. Tap "Environment" to start login.

```bash
# 1. Splash → TOS (tap "Environment", NOT "Continue")
pepper-ctl raw '{"cmd":"tap","params":{"text":"Environment"}}'
sleep 1

# 2. Scroll TOS, then accept
pepper-ctl raw '{"cmd":"swipe","params":{"direction":"up","from":{"x":210,"y":600},"amount":400}}'
sleep 0.5
pepper-ctl raw '{"cmd":"tap","params":{"text":"Accept and continue"}}'
sleep 1.5

# 3. Enter email (empty field — works reliably)
pepper-ctl raw '{"cmd":"input","params":{"class":"UITextField","index":0,"value":"user@example.com","clear":true}}'
pepper-ctl raw '{"cmd":"tap","params":{"text":"Continue"}}'
sleep 2

# 4. Enter password + confirm (use python for special chars, Tab between fields)
python3 -c "
import subprocess, json
cmd = json.dumps({'cmd':'input','params':{'class':'UITextField','index':0,'value':'YourPassword!123'}})
result = subprocess.run(['./tools/pepper-ctl','raw',cmd], capture_output=True, text=True)
print(result.stdout or result.stderr)
"
# Tab to confirm password (key code 48)
osascript -e 'tell application "Simulator" to activate' && sleep 0.3
osascript -e 'tell application "System Events" to key code 48' && sleep 0.3
python3 -c "
import subprocess, json
cmd = json.dumps({'cmd':'input','params':{'class':'UITextField','index':1,'value':'YourPassword!123'}})
result = subprocess.run(['./tools/pepper-ctl','raw',cmd], capture_output=True, text=True)
print(result.stdout or result.stderr)
"
pepper-ctl raw '{"cmd":"tap","params":{"text":"Continue"}}'
sleep 2

# 5. Enter name (First + Last, Tab between)
pepper-ctl raw '{"cmd":"input","params":{"class":"UITextField","index":0,"value":"Test","clear":true}}'
osascript -e 'tell application "Simulator" to activate' && sleep 0.3
osascript -e 'tell application "System Events" to key code 48' && sleep 0.3
pepper-ctl raw '{"cmd":"input","params":{"class":"UITextField","index":1,"value":"User","clear":true}}'
pepper-ctl raw '{"cmd":"tap","params":{"text":"Continue"}}'
sleep 2

# 6. Enter phone number (field already focused)
pepper-ctl raw '{"cmd":"input","params":{"value":"5551234567","clear":true}}'
pepper-ctl raw '{"cmd":"tap","params":{"text":"Continue"}}'
sleep 3

# 7. Verify logged in
pepper-ctl look
```

### swipe vs scroll

Both `scroll` (direction mode) and `swipe` use real touch synthesis — they generate touch began/moved/ended events through the UIKit event pipeline. The difference is ergonomics:
- **`scroll`** is higher-level: specify direction + amount, auto-targets the visible scroll view.
- **`swipe`** is lower-level: specify explicit from/to coordinates or element-relative directions.

Both trigger gesture recognizers, pull-to-refresh, swipe-to-dismiss, and other gesture-driven behaviors.

> **Note**: `scroll` element mode (`{"element": "id"}`) still uses programmatic `scrollRectToVisible` — it's a utility for making an element visible, not a user gesture simulation.

### System dialogs (permissions, alerts)

`tap text:` searches ALL visible windows front-to-back (highest windowLevel first). System permission dialogs appear in a window above the app — `tap text:"Allow While Using App"` will find and tap the button directly.

For automatic handling, enable auto-dismiss before running tests:
```json
{"cmd":"dialog","params":{"action":"auto_dismiss","enabled":true}}
```
This auto-taps "Allow While Using App", "Allow Once", "Allow", or "OK" on any system dialog within 300ms.

The dialog interceptor broadcasts `dialog_appeared` events when any alert is presented, including permission requests. Tests can listen for these events and respond with specific button taps.

### General Workflow

1. **Always `ping` first** to confirm the control plane is up.
2. **Verify after every action** — use `look` to confirm state before proceeding.
3. **Use `pepper-ctl raw`** for full control — the CLI subcommands (`tap --text`, `input --id`) have their own argument parsing that can interfere with special characters or complex params.
4. **Add `sleep` between commands** that trigger navigation (1-2s for screen transitions, 3s for login/network calls).
5. **Use `introspect` with `mode: accessibility`** to discover elements before interacting.
6. **Use `swipe` for gesture-driven interactions** (dismiss sheets, pull-to-refresh). Use `scroll` for simple content scrolling.

---

## vars — Runtime Variable Inspection & Mutation

Discover, read, and mutate `@Published` properties on live ObservableObject instances. Also mirrors ALL stored properties (not just @Published) for full state inspection.

### Actions

**list** — List all discovered instances and their @Published properties with current values:
```json
{"cmd":"vars","params":{"action":"list"}}
```

**discover** — Force re-scan the VC hierarchy for ObservableObject instances:
```json
{"cmd":"vars","params":{"action":"discover"}}
```

**dump** — Dump all @Published property values of a class:
```json
{"cmd":"vars","params":{"action":"dump","class":"HomeViewModel"}}
```

**mirror** — Mirror ALL properties (not just @Published) of a class. Shows stored, computed, and wrapper-backed properties:
```json
{"cmd":"vars","params":{"action":"mirror","class":"HomeViewModel"}}
```
Returns per-property: `name`, `type`, `value`, `published` (bool), `writable` (bool — only @Published).

**get** — Read a single property value:
```json
{"cmd":"vars","params":{"action":"get","path":"HomeViewModel.isLoading"}}
```

**set** — Write a property value and trigger SwiftUI re-render:
```json
{"cmd":"vars","params":{"action":"set","path":"HomeViewModel.isLoading","value":false}}
```

---

## layers — Deep CALayer Inspection

Hit-test a screen coordinate and return the full CALayer subtree with visual properties. Useful for debugging gradients, colors, shadows, shapes, and corner radii without visual captures.

### Usage

```json
{"cmd":"layers","params":{"point":"200,400"}}
{"cmd":"layers","params":{"point":"200,400","depth":5}}
```

### Response

Returns a nested tree rooted at the hit view's layer:
- **class**: CALayer subclass name (CAGradientLayer, CAShapeLayer, CATextLayer, etc.)
- **frame**: Window coordinates `{x, y, width, height}`
- **properties**: cornerRadius, masksToBounds, backgroundColor (hex), borderColor, borderWidth, opacity, isHidden, shadow*, sublayer_count
- **Type-specific**: CAGradientLayer → colors (hex array), locations, startPoint, endPoint, gradientType. CAShapeLayer → fillColor, strokeColor, lineWidth, pathBounds. CATextLayer → string, fontSize, foregroundColor.
- **sublayers**: Recursive children (up to `depth` limit, default 20)

---

## console — App stderr/NSLog Capture

Capture the app's stderr output (NSLog, os_log, print-to-stderr) into a ring buffer. Query, filter, and clear the buffer. While active, each line is broadcast as a `console` event for real-time streaming via `pepper-stream`.

### Actions

**start** — Begin capturing stderr:
```json
{"cmd":"console","params":{"action":"start"}}
{"cmd":"console","params":{"action":"start","buffer_size":2000}}
```

**stop** — Stop capturing and restore stderr:
```json
{"cmd":"console","params":{"action":"stop"}}
```

**log** — Query the buffer (most recent lines, optional filter):
```json
{"cmd":"console","params":{"action":"log","limit":50,"filter":"gradient"}}
```

**status** — Check capture state:
```json
{"cmd":"console","params":{"action":"status"}}
```

**clear** — Empty the buffer:
```json
{"cmd":"console","params":{"action":"clear"}}
```

---

## animations — Animation Inspection & Tracing

Scan all active CAAnimations across the layer tree, or trace a specific view's movement over time by sampling its `presentationLayer`.

### Actions

**scan** (default) — Find all active animations across all windows:
```json
{"cmd":"animations"}
{"cmd":"animations","params":{"action":"scan"}}
```

Returns per animation:
- `key`, `anim_class` (CABasicAnimation, CASpringAnimation, CAKeyframeAnimation, etc.)
- `key_path` (position, opacity, transform, backgroundColor, etc.)
- `from_value`, `to_value`, `current_value` — interpolated from presentationLayer
- `duration`, `timing_function`, `progress` (0→1)
- `spring` — damping, stiffness, mass, initialVelocity, settlingDuration (for CASpringAnimation)
- `values`, `key_times`, `path_bounds` (for CAKeyframeAnimation)
- `layer_class`, `layer_frame`, `depth` — where in the tree this animation lives
- `is_infinite` — whether this is a decorative/looping animation

**trace** — Sample a view's position, bounds, opacity, and transform over time:
```json
{"cmd":"animations","params":{"action":"trace","point":"200,400"}}
{"cmd":"animations","params":{"action":"trace","point":"200,400","duration_ms":500,"interval_ms":16}}
```

Hit-tests the point to find the view, then samples `presentationLayer` at the given interval (default 16ms ≈ 60fps) for the given duration (default 500ms). Each sample includes:
- `t_ms` — elapsed time
- `position`, `window_position` — layer-local and window coordinates
- `bounds`, `opacity`
- `transform` — decomposed into scale_x, scale_y, rotation_deg, translate_x, translate_y
- `active_animations` — animation keys active at that sample

Use trace to understand animation curves, timing, and paths. Pair with `animation_speed speed:0.1` to slow everything down for detailed tracing.

---

## hook — Runtime Method Hooking

Intercept any ObjC method call at runtime. Logs invocations with arguments and call counts, then calls through to the original implementation. Useful for understanding app behavior without modifying source code.

**WARNING:** Only hook app-specific or third-party classes. System framework classes (NSObject, NSString, UIView, UIViewController, etc.) are blocked — hooking them would crash the app or the hook engine itself.

### Actions

**install** — Hook a method:
```json
{"cmd":"hook","params":{"action":"install","class":"HomeViewModel","method":"viewDidAppear:"}}
{"cmd":"hook","params":{"action":"install","class":"NetworkClient","method":"performRequest:completion:","class_method":false}}
```

| Param | Type | Required | Description |
|-------|------|----------|-------------|
| `class` | string | **yes** | ObjC class name (e.g. `"HomeViewModel"`). |
| `method` | string | **yes** | Selector name (e.g. `"viewDidAppear:"`, `"performRequest:completion:"`). |
| `class_method` | bool | no | Hook a class method (+) instead of instance method (-). Default: `false`. |

Response:
```json
{"status":"ok","data":{"hook_id":"hook_1","class":"HomeViewModel","method":"viewDidAppear:","encoding":"v@:B"}}
```

**remove** — Remove a hook (restores original implementation):
```json
{"cmd":"hook","params":{"action":"remove","id":"hook_1"}}
```

**remove_all** — Remove all hooks:
```json
{"cmd":"hook","params":{"action":"remove_all"}}
```

**list** — List installed hooks with call counts:
```json
{"cmd":"hook","params":{"action":"list"}}
```

**log** — Get recent call log entries:
```json
{"cmd":"hook","params":{"action":"log","id":"hook_1","limit":20}}
{"cmd":"hook","params":{"action":"log","limit":50}}
```
Omit `id` to get entries from all hooks (merged, sorted by timestamp).

**clear** — Clear call log:
```json
{"cmd":"hook","params":{"action":"clear","id":"hook_1"}}
{"cmd":"hook","params":{"action":"clear"}}
```

### Supported Signatures

~90% of common ObjC methods are supported:
- **Return types:** void, object (id), BOOL
- **Argument types:** 0-3 object args, 1 BOOL arg, mixed object+BOOL combinations
- Methods with struct returns (CGRect, CGSize) or integer/float args are not yet supported — install will return an error with the encoding.

### Blocked Classes

System framework classes are rejected to prevent crashes:
- Foundation roots: NSObject, NSProxy
- Strings: NSString, NSMutableString (and internal variants)
- Collections: NSArray, NSDictionary, NSSet (and mutable/internal variants)
- Numbers: NSNumber, NSValue
- Runtime: NSMethodSignature, NSInvocation, NSBlock
- UIKit base: UIView, UIResponder, UIViewController, UIScrollView, UIWindow, UIApplication

---

## find — NSPredicate Element Queries

Query elements using native NSPredicate expressions. Evaluates predicates against element properties discovered from the accessibility tree and view hierarchy.

### Usage

```json
{"cmd":"find","params":{"predicate":"label CONTAINS 'Save'"}}
{"cmd":"find","params":{"predicate":"type == 'button' AND hitReachable == true","limit":5}}
```

| Param | Type | Required | Description |
|-------|------|----------|-------------|
| `predicate` | string | **yes** | NSPredicate format string. |
| `limit` | int | no | Max results (default: 10). |
| `hit_test` | bool | no | Filter to hit-reachable elements only (default: `true`). |
| `tap` | bool | no | Tap the first match (default: `false`). |
| `tap_index` | int | no | When `tap:true`, tap the Nth match (default: 0). |

### Available Properties

| Property | Type | Description |
|----------|------|-------------|
| `label` | string | Accessibility label |
| `type` | string | Element type (button, textField, etc.) |
| `className` | string | UIKit class name |
| `x`, `y`, `width`, `height` | number | Frame coordinates |
| `centerX`, `centerY` | number | Center point |
| `hitReachable` | bool | Topmost at its position (not behind modal) |
| `enabled` | bool | Element is enabled |
| `traits` | array | Accessibility traits |

### Example Predicates

```
label CONTAINS 'Save'
type == 'button' AND hitReachable == true
label LIKE '*Settings*' AND enabled == true
'selected' IN traits
centerY > 400 AND centerY < 600
```

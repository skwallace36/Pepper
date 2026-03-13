---
name: pepper
description: Pepper dylib development mode. Use the injected dylib to see, interact with, and iterate on the running iOS app.
version: 3.0.0
allowedCommands:
  - "python3 */pepper-ctl*"
  - "python3 */pepper-context*"
  - "make build*"
  - "make launch"
  - "make ping"
  - "xcrun simctl*"
  - "lsof*"
  - "kill*"
---

# Pepper — Development Mode

Pepper is a dylib injected into the iOS simulator app. It gives you full runtime access — see every element, tap anything, read state, inspect layers, capture logs — all through CLI commands. No screenshots. No print statements.

## RULES

1. **NEVER SCREENSHOT. NEVER.** Not `xcrun simctl io screenshot`, not saving PNGs, not any visual capture. Use `$P look` instead. If `look` isn't working, FIX PEPPER — don't fall back to screenshots.
2. **NEVER add print/NSLog and rebuild to debug.** You have runtime inspection tools — use them.
3. **Use CLI shortcuts first.** `$P look`, `$P tap --text "label"`, `$P scroll --direction down`. Fall back to `$P raw '{...}'` only for commands without shortcuts.
4. **Point format varies by command.** `tap` uses object: `"point":{"x":200,"y":400}`. `layers`/`animations trace` use string: `"point":"200,400"`.

## Setup

### Find the pepper repo

```bash
PEPPER_DIR=""
for dir in "$(dirname "$(dirname "$(dirname "$0")")")" "$HOME/Developer/pepper" "$HOME/pepper"; do
  if [ -f "$dir/tools/pepper-ctl" ]; then PEPPER_DIR="$dir"; break; fi
done
```

If not found, ask the user where the pepper repo is cloned.

### Command Prefix

```
P="python3 <PEPPER_DIR>/tools/pepper-ctl"
```

**Multiple simulators**: When more than one sim is booted, you MUST specify the target:
```
P="python3 <PEPPER_DIR>/tools/pepper-ctl --simulator <UDID>"
```
Check booted sims: `xcrun simctl list devices booted`. Check port files: `ls /tmp/pepper-ports/`.

### Check connection
```bash
$P ping
```

### If ping fails — the dylib isn't running

Terminate and relaunch with injection:
```bash
xcrun simctl terminate <UDID> <BUNDLE_ID>
SIMCTL_CHILD_DYLD_INSERT_LIBRARIES="<PEPPER_DIR>/build/Pepper.framework/Pepper" xcrun simctl launch <UDID> <BUNDLE_ID>
```
If the dylib isn't built yet: `cd <PEPPER_DIR> && make build` first.

### Orient after connecting
Run `$P look`. Report what screen we're on and what's interactive.

## See the Screen

| What | Command |
|------|---------|
| **Quick look (USE THIS FIRST)** | `$P look` |
| Quick look + raw JSON | `$P --json look` |
| Current screen name | `$P screen` |

`look` returns: screen name, all interactive elements with exact tap commands, and visible text. Use `--json` when you need coordinates, frames, or scroll context.

## Interact

| What | Command |
|------|---------|
| Tap by text/label | `$P tap --text "Continue"` |
| Tap by coordinates | `$P tap --point 200,400` |
| Scroll down | `$P scroll --direction down` |
| Scroll with amount | `$P scroll --direction down --amount 400` |
| Go back | `$P back` |
| Navigate via deeplink | `$P navigate --deeplink home` |
| Type text | `$P raw '{"cmd":"input","params":{"id":"field","value":"hello"}}'` |
| Tap by icon name | `$P raw '{"cmd":"tap","params":{"icon_name":"gift-fill-icon"}}'` |
| Tap by heuristic | `$P raw '{"cmd":"tap","params":{"heuristic":"menu_button"}}'` |
| Dismiss modal | `$P raw '{"cmd":"dismiss"}'` |

## Inspect Runtime State

| What | Command |
|------|---------|
| List tracked ViewModels | `$P raw '{"cmd":"vars","params":{"action":"list"}}'` |
| Dump @Published values | `$P raw '{"cmd":"vars","params":{"action":"dump","class":"MyVM"}}'` |
| Mirror ALL properties | `$P raw '{"cmd":"vars","params":{"action":"mirror","class":"MyVM"}}'` |
| Set a property live | `$P raw '{"cmd":"vars","params":{"action":"set","path":"MyVM.flag","value":true}}'` |
| Search loaded classes | `$P raw '{"cmd":"heap","params":{"action":"classes","pattern":"Manager"}}'` |
| List live controllers | `$P raw '{"cmd":"heap","params":{"action":"controllers"}}'` |
| Find singleton instance | `$P raw '{"cmd":"heap","params":{"action":"find","class":"AppCoordinator"}}'` |

## Inspect Visual Rendering

| What | Command |
|------|---------|
| Layer tree at point | `$P raw '{"cmd":"layers","params":{"point":"200,400"}}'` |
| Layer tree (limited) | `$P raw '{"cmd":"layers","params":{"point":"200,400","depth":3}}'` |

## Inspect Animations

| What | Command |
|------|---------|
| Scan all active animations | `$P raw '{"cmd":"animations"}'` |
| Trace view movement | `$P raw '{"cmd":"animations","params":{"action":"trace","point":"200,400"}}'` |
| Slow-mo for tracing | `$P raw '{"cmd":"animation_speed","params":{"speed":0.1}}'` |
| Restore normal speed | `$P raw '{"cmd":"animation_speed","params":{"speed":1}}'` |

## Capture App Logs

| What | Command |
|------|---------|
| Start capture | `$P raw '{"cmd":"console","params":{"action":"start"}}'` |
| Read recent logs | `$P raw '{"cmd":"console","params":{"action":"log","limit":50}}'` |
| Filter logs | `$P raw '{"cmd":"console","params":{"action":"log","filter":"error"}}'` |
| Stop capture | `$P raw '{"cmd":"console","params":{"action":"stop"}}'` |

## Monitor Network

| What | Command |
|------|---------|
| Start capture | `$P raw '{"cmd":"network","params":{"action":"start"}}'` |
| View traffic | `$P raw '{"cmd":"network","params":{"action":"log","limit":10}}'` |
| Filter by URL | `$P raw '{"cmd":"network","params":{"action":"log","filter":"api.example"}}'` |

## Debugging Workflow

When something isn't working, follow this sequence. **Every step is a command — no rebuilding needed.**

```
1. $P look                                                → What's on screen?
2. $P --json look                                         → Need coordinates/frames?
3. $P raw '{"cmd":"vars","params":{"action":"list"}}'     → What ViewModels exist?
4. $P raw '{"cmd":"vars","params":{"action":"mirror","class":"MyVM"}}' → Full property dump
5. $P raw '{"cmd":"vars","params":{"action":"set","path":"MyVM.flag","value":true}}' → Test a theory
6. $P raw '{"cmd":"layers","params":{"point":"200,400"}}' → Layer tree at that spot
7. $P raw '{"cmd":"console","params":{"action":"start"}}' → Start capturing logs
8. $P raw '{"cmd":"console","params":{"action":"log"}}'   → Read captured logs
9. $P raw '{"cmd":"heap","params":{"action":"controllers"}}' → Live VC hierarchy
10. $P raw '{"cmd":"network","params":{"action":"start"}}' → Start capturing HTTP
```

**If you've exhausted all 10 steps and still can't figure it out, THEN consider a rebuild.** Not before.

## Tap Fallbacks

If `tap --text` doesn't find an element:
1. `$P look` to see all elements and their tap commands
2. `$P --json look` to get exact coordinates
3. `$P tap --point x,y` to tap by coordinate

## Multi-Sim

One sim: pepper-ctl auto-discovers port. Multiple sims: use `--simulator <UDID>` (preferred) or `--port <PORT>`. Always check `xcrun simctl list devices booted` first.

## Rebuild Cycle

When a rebuild IS needed (structural changes — new views, new properties, new signatures):
```bash
cd <PEPPER_DIR> && make deploy
```

For runtime-tunable changes (values behind @Published/notification bridge): just send a `vars action:set` command. No rebuild needed.

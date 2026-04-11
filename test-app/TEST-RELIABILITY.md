# Test Reliability

Reference for agent-driven test reliability: timeouts, retries, reset, and flaky detection.

## wait_for Timeout Guide

`wait_for` polls for a condition with a configurable `timeout_ms` (default: 5000ms). Use these values based on what you're waiting for:

| Scenario | Recommended timeout_ms | Why |
|---|---|---|
| Element already visible (just confirming) | 2000 | Should resolve in one poll cycle |
| UI animation (sheet, nav push, tab switch) | 3000 | iOS animations are typically 250-350ms |
| Text field value update after input | 3000 | Synchronous in most cases |
| Network fetch (local/cached) | 5000 | Default; covers most fast API calls |
| Network fetch (remote, moderate) | 10000 | Accounts for real latency + parsing |
| Heavy computation / large list render | 10000 | SwiftUI lazy rendering can be slow |
| Simulated network conditions (latency injection) | 15000 | Latency adds to real response time |
| App startup / cold launch settle | 8000 | First render + data load + animations |
| Pull-to-refresh completion | 5000 | Network fetch + UI update |

### wait_idle

`wait_idle` detects when the app is idle (no animations, no pending dispatches, no VC transitions). It doesn't take a timeout — it returns `{idle: bool, elapsed_ms: N}`.

Use `wait_idle` after navigation actions. Use `wait_for` when you need a specific condition met.

## Retry Policy

### Safe to retry (up to 1 retry)

These commands are idempotent or have no lasting side effects on failure:

- **Observation:** `look`, `find`, `read_element`, `screen`, `tree`, `verify`, `status`
- **Waits:** `wait_for`, `wait_idle`
- **Taps/input:** `tap`, `input_text`, `toggle`, `scroll`, `swipe`, `gesture`
- **Navigation:** `navigate`, `back`, `dismiss`, `dismiss_keyboard`
- **Read-only inspection:** `snapshot diff`, `defaults list`, `flags list`, `vars_inspect`, `responder_chain`, `clipboard read`, `console log`, `network log`, `timeline query`

### Do NOT retry

These commands have side effects that would double up on retry:

- **State mutations:** `flags set`, `defaults write`, `clipboard write`, `push`
- **Lifecycle actions:** `console start/stop`, `network start/stop`, `notifications start/stop`, `renders start/stop`
- **Destructive:** `snapshot delete/clear`, `network clear_mocks/clear_conditions`
- **Test lifecycle:** `test start`, `test result` (double-reporting corrupts results)

### Retry flow

```
1. Execute command
2. If error response:
   a. Call `test reset` to clean up (if the error might be stale state)
   b. Call `look` to verify app is responsive
   c. Retry the command once
   d. If still failing, mark as fail and move on
3. If app crash:
   a. Use `crash_log` to capture details
   b. Restart with `make test-deploy` or `build_and_deploy`
   c. Retry the failed test once from the beginning
```

### Backoff

No exponential backoff needed within a single test run. The 300ms auto-idle pause after UI actions provides sufficient settling time. If you need more time, use `wait_for` with an appropriate timeout rather than sleeping.

## Test Reset

Call `test reset` between test cases to ensure clean state:

```json
{"cmd": "test", "params": {"action": "reset"}}
```

This:
1. Dismisses all presented modals/sheets
2. Pops all navigation stacks to root
3. Stops active monitors (console, network, notifications, renders)
4. Clears highlights, snapshots, and flag overrides
5. Returns a cleanup summary

### When to reset

- **Between unrelated test cases.** If test A navigates deep into a screen and test B needs the home screen, reset between them.
- **After a test failure.** Failed tests may leave the app in unexpected state.
- **After testing monitor commands.** Console/network/notification monitors stay active until explicitly stopped.

### When NOT to reset

- **Between related steps in one test.** If you're testing a multi-step flow (navigate → tap → verify), don't reset between steps.
- **Before the very first test.** The app starts clean.

## Flaky Detection

Use `scripts/flaky-detect.sh` to check if a command produces consistent results:

```bash
# Run 'look' 5 times, check for consistency
./scripts/flaky-detect.sh look 5

# Run a tap 5 times with params
./scripts/flaky-detect.sh tap 5 '{"text":"Tap Me"}'

# Run wait_for 5 times
./scripts/flaky-detect.sh wait_for 5 '{"until":{"text":"Hello"},"timeout_ms":3000}'
```

Exit codes:
- `0` — consistent (all pass or all fail)
- `1` — flaky (mixed results)

### Common flaky patterns

| Pattern | Cause | Fix |
|---|---|---|
| tap misses intermittently | Animation not settled | Add `wait_for` before tap, or increase auto-idle |
| look returns different element counts | Lazy rendering, async data | Use `wait_for` to confirm expected elements first |
| scroll doesn't reach target | Variable content height | Use `scroll_to` with target instead of blind scroll |
| wait_for times out sometimes | Timeout too tight | Increase timeout_ms per the guide above |
| network log empty after request | Monitor not started | Ensure `network start` before triggering requests |

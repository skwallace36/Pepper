# Bugs

All known bugs go here. Referenced by `test-app/COVERAGE.md` (auto-generated) and `ROADMAP.md`.

Format: `BUG-NNN` ID, component tag, `status:<status>`, description, date found.
Statuses: `open` → `in-progress` → `pr-open` → `fixed`.

- **BUG-001** `[dylib/back]` `status:pr-open` — SwiftUI NavigationStack depth not correctly detected. After pushing 3 levels deep, first `back` pops but second reports "already at root" while still on the Detail screen. Pepper likely only checks UINavigationController's viewControllers count, which SwiftUI populates differently. *(found: 2026-03-21)*

- **BUG-002** `[dylib/layers]` `status:pr-open` — Sending `layers` with a point targeting a SwiftUI gradient view crashes the app (WebSocket connection lost). Needs crash log investigation. *(found: 2026-03-21)*

- **BUG-003** `[dylib/vars]` `status:pr-open` — `vars action:list` returns 0 instances because Pepper scans for `@Published` on `ObservableObject`. Swift 5.9 `@Observable` macro (Observation framework) uses a completely different mechanism — not detected. *(found: 2026-03-21)*

- **BUG-004** `[dylib/scroll_to]` `status:open` — `ScrollUntilVisibleHandler` does not override `var timeout: TimeInterval`, so the server-side dispatch timeout (10s) fires before long scrolls complete. The handler keeps running and the scroll succeeds, but the client receives a premature timeout error. Fix: override `timeout` to match or exceed `timeout_ms` parameter (default 10s → should be ~15-20s to account for max_scrolls * swipe+settle time). *(found: 2026-03-21)*

---

**Routing:** Work items → `ROADMAP.md` | Test coverage → `test-app/COVERAGE.md` | Research → `docs/RESEARCH.md`

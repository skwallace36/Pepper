# Bugs

All known bugs go here. Referenced by `test-app/COVERAGE.md` (auto-generated) and `ROADMAP.md`.

Format: `BUG-NNN` ID, component tag, description, date found.

## Open

- **BUG-001** `[dylib/back]` SwiftUI NavigationStack depth not correctly detected. After pushing 3 levels deep, first `back` pops but second reports "already at root" while still on the Detail screen. Pepper likely only checks UINavigationController's viewControllers count, which SwiftUI populates differently. *(found: 2026-03-21)*

- **BUG-002** `[dylib/layers]` Sending `layers` with a point targeting a SwiftUI gradient view crashes the app (WebSocket connection lost). Needs crash log investigation. *(found: 2026-03-21)*

- **BUG-003** `[dylib/vars]` `vars action:list` returns 0 instances because Pepper scans for `@Published` on `ObservableObject`. Swift 5.9 `@Observable` macro (Observation framework) uses a completely different mechanism — not detected. *(found: 2026-03-21)*

## Fixed

*(none yet)*

---

**Routing:** Work items → `ROADMAP.md` | Test coverage → `test-app/COVERAGE.md` | Research → `docs/RESEARCH.md`

# test-app/

Purpose-built SwiftUI/UIKit app for testing every Pepper command. No business logic — just UI surfaces that exercise Pepper's capabilities.

Bundle ID: `com.pepper.testapp`

## Build & Run

```bash
# Build the test app
xcodebuild -project test-app/PepperTestApp.xcodeproj \
  -scheme PepperTestApp -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -configuration Debug build

# Install on a booted sim
xcrun simctl install booted \
  ~/Library/Developer/Xcode/DerivedData/PepperTestApp-*/Build/Products/Debug-iphonesimulator/PepperTestApp.app

# Or just set .env and use make deploy
echo 'APP_BUNDLE_ID=com.pepper.testapp' > .env
echo 'APP_ADAPTER_TYPE=generic' >> .env
make deploy
```

## Structure

- `PepperTestApp.swift` — app entry point
- `AppState.swift` — `@Observable` state object with counters, toggles, text, timer, network
- `ContentView.swift` — 3-tab TabView (Controls, List, Misc)
- `ControlsView.swift` — buttons, toggles, segmented control, slider, text input, date picker, stepper, nav links, sheet, alert, long press
- `DetailView.swift` — nav stack push target (2 levels: Detail → Deeper)
- `SheetView.swift` — sheet with nested sheet (for dismiss testing)
- `ListTab.swift` — 30-row scrollable list with search, swipe actions, pull-to-refresh
- `MiscTab.swift` — gradient/shadow layers, animations, timer, HTTP fetch, pinch-to-zoom, WKWebView, MapKit, UIKit hosted VC, context menu
- `UIKitControlsView.swift` — UIViewControllerRepresentable wrapping a UIKit VC with native controls

## What It Tests

See `COVERAGE.md` for the command-by-command status matrix.

The app provides surfaces for: element discovery (`look`), all tap strategies, text input, toggles, scroll/swipe, navigation (push/pop/sheet/dismiss/alert), state inspection (`vars`, `heap`), layer inspection, console logging, network interception, animation detection, and gesture recognition.

## Adding Test Surfaces

When adding a new Pepper command or fixing a bug, add the corresponding UI surface here and update `COVERAGE.md`. The test app should always cover everything Pepper can do.

---

**Routing:** Bugs → GitHub Issues (`gh issue list --label bug`) | Work items → `../ROADMAP.md` | Test coverage → `COVERAGE.md` | Research → `../docs/RESEARCH.md`

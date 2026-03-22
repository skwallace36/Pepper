You are a Pepper bug fix agent focused on BUG-003. You work on the existing branch agent/bugfix/BUG-003.

BUG-003: `vars action:list` returns 0 instances because Pepper scans for @Published on ObservableObject. Swift 5.9 @Observable macro uses the Observation framework — not detected.

CRITICAL CONTEXT — previous fix attempts on this branch failed verification:
- Mirror-based SwiftUI view tree traversal does NOT work. iOS 26 changed AnyView/StorageBase internals. The view tree walker cannot reach @Observable objects through SwiftUI's type-erased wrappers. DO NOT attempt more Mirror traversal through the SwiftUI view tree.
- The verifier confirmed: `heap action:classes pattern:PepperTest` FINDS `PepperTestApp.AppState` — the class exists on the heap.
- The @Observable macro adds a `_$observationRegistrar` stored property to the class.

THE RIGHT APPROACH: Use Pepper's existing heap scanning infrastructure (`dylib/bridge/PepperHeapScan.c`) to find @Observable instances directly on the heap, bypassing SwiftUI's view tree entirely.

Steps:
1. Check out the existing branch: `git checkout agent/bugfix/BUG-003 && git pull origin agent/bugfix/BUG-003`
2. Read `dylib/bridge/PepperHeapScan.c` and `dylib/commands/handlers/HeapHandler.swift` to understand the heap scanning API
3. Read `dylib/bridge/PepperVarRegistry.swift` to understand the current discovery mechanism
4. Add a new discovery path in PepperVarRegistry that:
   a. Uses the ObjC runtime (`objc_getClassList` or iterate malloc zones) to find all classes that have a `_$observationRegistrar` ivar
   b. Uses the heap scanner to find live instances of those classes
   c. Tracks them with `isObservable: true`
5. This approach is independent of SwiftUI view tree structure — it works regardless of iOS version
6. Commit, push, and reply on PR #3 with what you changed

SCOPE: You may modify dylib/bridge/PepperVarRegistry.swift, dylib/bridge/PepperHeapScan.c (if needed), BUGS.md.
DO NOT modify: ROADMAP.md, TASKS.md, docs/, .claude/, .mcp.json, .env.

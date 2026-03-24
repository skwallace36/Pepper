import Foundation
import os

/// Tracks pending main-queue dispatch blocks via DYLD_INTERPOSE interposition.
/// Provides Layer 3 idle detection: the app is not idle while async blocks are pending.
///
/// Uses DYLD_INTERPOSE to rebind `dispatch_async` and `dispatch_after` — when a block is
/// submitted to the main queue, the pending count increments; when the block completes,
/// it decrements. Only short-delay `dispatch_after` calls (<=1.5s) are tracked to
/// avoid counting background timers as pending UI work.
final class PepperDispatchTracker {
    static let shared = PepperDispatchTracker()

    private var logger: Logger { PepperLogger.logger(category: "dispatch-tracker") }

    /// Atomic counter of pending main-queue blocks. Updated from the C hook layer
    /// via the increment/decrement callbacks. Read from the main thread by idle checks.
    private let _pendingCount = ManagedAtomic<Int>(0)

    /// Whether hooks have been installed (idempotent guard).
    private static var installed = false

    private init() {}

    // MARK: - Installation

    /// Install DYLD_INTERPOSE-based dispatch interposition. Call once from PepperPlane.start().
    /// Safe to call multiple times — second call is a no-op.
    func install() {
        guard !Self.installed else { return }
        Self.installed = true

        // The C function accepts two @convention(c) function pointers.
        // We pass Swift closures that bridge into this singleton.
        _pepper_install_dispatch_hooks(
            { PepperDispatchTracker.shared.increment() },
            { PepperDispatchTracker.shared.decrement() }
        )
        logger.info("Dispatch tracker installed (DYLD_INTERPOSE interposition active)")
    }

    // MARK: - Counter

    /// Current number of pending main-queue dispatch blocks.
    var pendingBlockCount: Int {
        _pendingCount.value
    }

    /// Whether all tracked dispatch blocks have completed.
    var isIdle: Bool {
        _pendingCount.value <= 0
    }

    private func increment() {
        _pendingCount.increment()
    }

    private func decrement() {
        _pendingCount.decrement()
    }
}

// MARK: - C Bridge (via @_silgen_name)

/// Direct binding to the C function in dispatch_hook.c.
/// No bridging header or modulemap needed — the linker resolves the symbol
/// from the .o file that's linked into the same framework.
@_silgen_name("pepper_install_dispatch_hooks")
private func _pepper_install_dispatch_hooks(
    _ inc: @convention(c) () -> Void,
    _ dec: @convention(c) () -> Void
)

/// Direct binding to read the C-side atomic counter (for debugging).
@_silgen_name("pepper_dispatch_pending_count")
private func _pepper_dispatch_pending_count() -> Int32

// MARK: - Lock-Free Atomic Counter

/// Minimal lock-free atomic integer using os_unfair_lock.
/// Swift lacks native atomics in the standard library (pre-Swift 6),
/// and we can't import swift-atomics into a framework dylib build.
/// os_unfair_lock is the lightest kernel-backed lock on Darwin.
private final class ManagedAtomic<T: SignedInteger> {
    private var _value: T
    private var _lock = os_unfair_lock()

    init(_ value: T) {
        _value = value
    }

    var value: T {
        os_unfair_lock_lock(&_lock)
        defer { os_unfair_lock_unlock(&_lock) }
        return _value
    }

    func increment() {
        os_unfair_lock_lock(&_lock)
        _value += 1
        os_unfair_lock_unlock(&_lock)
    }

    func decrement() {
        os_unfair_lock_lock(&_lock)
        _value -= 1
        os_unfair_lock_unlock(&_lock)
    }
}

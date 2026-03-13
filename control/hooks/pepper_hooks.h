#ifndef pepper_hooks_h
#define pepper_hooks_h

/// Install fishhook-based interposition of dispatch_async and dispatch_after
/// on the main queue. The provided callbacks are invoked to increment/decrement
/// a pending-block counter for Layer 3 idle detection.
void pepper_install_dispatch_hooks(void (*inc_fn)(void), void (*dec_fn)(void));

/// Returns the current number of pending (hooked) main-queue dispatch blocks.
/// Useful for debugging — the Swift side reads this via PepperDispatchTracker.
int pepper_dispatch_pending_count(void);

#endif // pepper_hooks_h

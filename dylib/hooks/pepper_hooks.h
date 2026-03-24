#ifndef pepper_hooks_h
#define pepper_hooks_h

/// Register callbacks for DYLD_INTERPOSE-based dispatch_async/dispatch_after
/// interposition on the main queue. The interposition is always active (dyld
/// installs it at load time); this call just enables the tracking callbacks.
void pepper_install_dispatch_hooks(void (*inc_fn)(void), void (*dec_fn)(void));

/// Returns the current number of pending (hooked) main-queue dispatch blocks.
/// Useful for debugging — the Swift side reads this via PepperDispatchTracker.
int pepper_dispatch_pending_count(void);

#endif // pepper_hooks_h

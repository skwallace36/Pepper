// dispatch_hook.c — DYLD_INTERPOSE-based interposition of dispatch_async / dispatch_after
// on the main queue. Wraps submitted blocks to increment/decrement a pending counter,
// providing Layer 3 idle detection for EarlGrey-style dispatch queue tracking.
//
// DYLD_INTERPOSE is a native dyld mechanism: we declare replacement functions in a
// __DATA,__interpose section and dyld rebinds all other images at load time. Calls
// to the original from within this dylib are not interposed, so we can call through
// directly without saving function pointers.

#include "pepper_hooks.h"

#include <dispatch/dispatch.h>
#include <stdatomic.h>
#include <Block.h>
// DYLD_INTERPOSE macro — places a {replacement, original} tuple in __DATA,__interpose.
// dyld processes this section at image load and rebinds the symbol in all other images.
#define DYLD_INTERPOSE(_replacement, _replacee) \
    __attribute__((used)) static struct { const void *replacement; const void *replacee; } \
    _interpose_##_replacee __attribute__((section("__DATA,__interpose"))) = \
    { (const void *)(unsigned long)&_replacement, (const void *)(unsigned long)&_replacee }

// ---------------------------------------------------------------------------
// Atomic pending-block counter
// ---------------------------------------------------------------------------

static atomic_int g_pending_count = 0;

// Callbacks into Swift (set once by pepper_install_dispatch_hooks)
static void (*g_increment_fn)(void) = NULL;
static void (*g_decrement_fn)(void) = NULL;

// ---------------------------------------------------------------------------
// Maximum delay (in nanoseconds) for dispatch_after tracking.
// Blocks scheduled > 1.5s in the future are likely timers, not UI work.
// ---------------------------------------------------------------------------

static const uint64_t kMaxTrackedDelayNs = 1500000000ULL; // 1.5 seconds

// ---------------------------------------------------------------------------
// Replacement: dispatch_async
// ---------------------------------------------------------------------------

void pepper_interposed_dispatch_async(dispatch_queue_t queue, dispatch_block_t block) {
    if (queue == dispatch_get_main_queue() && g_increment_fn) {
        atomic_fetch_add(&g_pending_count, 1);
        g_increment_fn();

        dispatch_block_t copied = Block_copy(block);
        dispatch_async(queue, ^{
            copied();
            Block_release(copied);
            atomic_fetch_sub(&g_pending_count, 1);
            if (g_decrement_fn) g_decrement_fn();
        });
    } else {
        dispatch_async(queue, block);
    }
}

// ---------------------------------------------------------------------------
// Replacement: dispatch_after
// ---------------------------------------------------------------------------

void pepper_interposed_dispatch_after(dispatch_time_t when, dispatch_queue_t queue, dispatch_block_t block) {
    if (queue == dispatch_get_main_queue() && g_increment_fn) {
        // Only track short delays — long timers are background work, not UI settling.
        uint64_t now_ns = dispatch_time(DISPATCH_TIME_NOW, 0);
        uint64_t delay_ns = (when > now_ns) ? (when - now_ns) : 0;

        if (delay_ns <= kMaxTrackedDelayNs) {
            atomic_fetch_add(&g_pending_count, 1);
            g_increment_fn();

            dispatch_block_t copied = Block_copy(block);
            dispatch_after(when, queue, ^{
                copied();
                Block_release(copied);
                atomic_fetch_sub(&g_pending_count, 1);
                if (g_decrement_fn) g_decrement_fn();
            });
        } else {
            dispatch_after(when, queue, block);
        }
    } else {
        dispatch_after(when, queue, block);
    }
}

// ---------------------------------------------------------------------------
// DYLD_INTERPOSE declarations — dyld rebinds these at load time
// ---------------------------------------------------------------------------

DYLD_INTERPOSE(pepper_interposed_dispatch_async, dispatch_async);
DYLD_INTERPOSE(pepper_interposed_dispatch_after, dispatch_after);

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

void pepper_install_dispatch_hooks(void (*inc_fn)(void), void (*dec_fn)(void)) {
    g_increment_fn = inc_fn;
    g_decrement_fn = dec_fn;
}

int pepper_dispatch_pending_count(void) {
    return atomic_load(&g_pending_count);
}

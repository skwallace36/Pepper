// dispatch_hook.c — fishhook-based interposition of dispatch_async / dispatch_after
// on the main queue. Wraps submitted blocks to increment/decrement a pending counter,
// providing Layer 3 idle detection for EarlGrey-style dispatch queue tracking.

#include "fishhook.h"
#include "pepper_hooks.h"

#include <dispatch/dispatch.h>
#include <stdatomic.h>
#include <Block.h>

// ---------------------------------------------------------------------------
// Atomic pending-block counter
// ---------------------------------------------------------------------------

static atomic_int g_pending_count = 0;

// Callbacks into Swift (set once by pepper_install_dispatch_hooks)
static void (*g_increment_fn)(void) = NULL;
static void (*g_decrement_fn)(void) = NULL;

// ---------------------------------------------------------------------------
// Original function pointers (saved by fishhook)
// ---------------------------------------------------------------------------

static void (*orig_dispatch_async)(dispatch_queue_t queue, dispatch_block_t block) = NULL;
static void (*orig_dispatch_after)(dispatch_time_t when, dispatch_queue_t queue, dispatch_block_t block) = NULL;

// ---------------------------------------------------------------------------
// Maximum delay (in nanoseconds) for dispatch_after tracking.
// Blocks scheduled > 1.5s in the future are likely timers, not UI work.
// ---------------------------------------------------------------------------

static const uint64_t kMaxTrackedDelayNs = 1500000000ULL; // 1.5 seconds

// ---------------------------------------------------------------------------
// Replacement: dispatch_async
// ---------------------------------------------------------------------------

static void hooked_dispatch_async(dispatch_queue_t queue, dispatch_block_t block) {
    if (queue == dispatch_get_main_queue()) {
        atomic_fetch_add(&g_pending_count, 1);
        if (g_increment_fn) g_increment_fn();

        dispatch_block_t copied = Block_copy(block);
        orig_dispatch_async(queue, ^{
            copied();
            Block_release(copied);
            atomic_fetch_sub(&g_pending_count, 1);
            if (g_decrement_fn) g_decrement_fn();
        });
    } else {
        orig_dispatch_async(queue, block);
    }
}

// ---------------------------------------------------------------------------
// Replacement: dispatch_after
// ---------------------------------------------------------------------------

static void hooked_dispatch_after(dispatch_time_t when, dispatch_queue_t queue, dispatch_block_t block) {
    if (queue == dispatch_get_main_queue()) {
        // Only track short delays — long timers are background work, not UI settling.
        uint64_t now_ns = dispatch_time(DISPATCH_TIME_NOW, 0);
        uint64_t delay_ns = (when > now_ns) ? (when - now_ns) : 0;

        if (delay_ns <= kMaxTrackedDelayNs) {
            atomic_fetch_add(&g_pending_count, 1);
            if (g_increment_fn) g_increment_fn();

            dispatch_block_t copied = Block_copy(block);
            orig_dispatch_after(when, queue, ^{
                copied();
                Block_release(copied);
                atomic_fetch_sub(&g_pending_count, 1);
                if (g_decrement_fn) g_decrement_fn();
            });
        } else {
            orig_dispatch_after(when, queue, block);
        }
    } else {
        orig_dispatch_after(when, queue, block);
    }
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

void pepper_install_dispatch_hooks(void (*inc_fn)(void), void (*dec_fn)(void)) {
    g_increment_fn = inc_fn;
    g_decrement_fn = dec_fn;

    struct rebinding rebindings[] = {
        {"dispatch_async", (void *)hooked_dispatch_async, (void **)&orig_dispatch_async},
        {"dispatch_after", (void *)hooked_dispatch_after, (void **)&orig_dispatch_after},
    };
    rebind_symbols(rebindings, 2);
}

int pepper_dispatch_pending_count(void) {
    return atomic_load(&g_pending_count);
}

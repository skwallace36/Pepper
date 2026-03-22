/// Heap instance scanning via malloc zone enumeration.
/// Written in C because the zone enumerator requires @convention(c) callbacks
/// that can't capture context in Swift. Uses the same technique as FLEX.
///
/// Two entry points:
///   pepper_heap_scan            — count instances per class (existing)
///   pepper_heap_find_instances  — collect instance pointers for target classes (BUG-003)

#include <malloc/malloc.h>
#include <mach/mach.h>
#include <objc/runtime.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdint.h>
#include <string.h>
#include <stdlib.h>

// The ObjC runtime exports this for isa masking on arm64
extern uint64_t objc_debug_isa_class_mask __attribute__((weak_import));

// Maximum classes we'll track
#define MAX_TRACKED_CLASSES 8192

// Result entry: class name + instance count
typedef struct {
    const char *class_name;
    int count;
} PepperHeapEntry;

// Scan context passed through the C callbacks
typedef struct {
    CFMutableSetRef registered_classes;
    // Use parallel arrays instead of CFDictionary for simplicity
    const void *class_ptrs[MAX_TRACKED_CLASSES];
    int class_counts[MAX_TRACKED_CLASSES];
    int class_count;
    uint64_t isa_mask;
} PepperHeapContext;

// Reader callback for in-process enumeration (identity function)
static kern_return_t heap_reader(
    task_t task,
    vm_address_t address,
    vm_size_t size,
    void **local_memory
) {
    *local_memory = (void *)address;
    return KERN_SUCCESS;
}


// Find or insert a class pointer in the context arrays
static int find_or_insert_class(PepperHeapContext *ctx, const void *cls) {
    for (int i = 0; i < ctx->class_count; i++) {
        if (ctx->class_ptrs[i] == cls) return i;
    }
    if (ctx->class_count >= MAX_TRACKED_CLASSES) return -1;
    int idx = ctx->class_count;
    ctx->class_ptrs[idx] = cls;
    ctx->class_counts[idx] = 0;
    ctx->class_count++;
    return idx;
}

// Range recorder: called for each batch of in-use malloc allocations
static void heap_recorder(
    task_t task,
    void *context,
    unsigned type,
    vm_range_t *ranges,
    unsigned count
) {
    if (type != MALLOC_PTR_IN_USE_RANGE_TYPE || !context || !ranges) return;
    PepperHeapContext *ctx = (PepperHeapContext *)context;

    for (unsigned i = 0; i < count; i++) {
        vm_range_t range = ranges[i];
        if (range.size < sizeof(void *)) continue;

        // Read the first pointer-sized word as a potential isa
        uint64_t isa_raw = *(uint64_t *)range.address;
        uint64_t isa_masked = isa_raw & ctx->isa_mask;

        const void *class_ptr = (const void *)(uintptr_t)isa_masked;
        if (!class_ptr) continue;

        // Check if this isa points to a known registered ObjC class
        if (CFSetContainsValue(ctx->registered_classes, class_ptr)) {
            int idx = find_or_insert_class(ctx, class_ptr);
            if (idx >= 0) {
                ctx->class_counts[idx]++;
            }
        }
    }
}

/// Scan the heap and return instance counts for all ObjC classes.
///
/// Returns a malloc'd array of PepperHeapEntry (caller must free).
/// Sets *out_count to the number of entries.
/// Filters to classes whose names contain a dot (module.ClassName) or
/// match any of the provided prefix strings.
///
/// Called from Swift via @_silgen_name.
int pepper_heap_scan(
    PepperHeapEntry **out_entries,
    int *out_count,
    const char **filter_prefixes,
    int prefix_count
) {
    *out_entries = NULL;
    *out_count = 0;

    // Step 1: Build set of all registered ObjC classes
    unsigned int total_class_count = 0;
    Class *all_classes = objc_copyClassList(&total_class_count);
    if (!all_classes || total_class_count == 0) return -1;

    CFMutableSetRef registered = CFSetCreateMutable(NULL, total_class_count, NULL);
    for (unsigned int i = 0; i < total_class_count; i++) {
        CFSetAddValue(registered, (const void *)all_classes[i]);
    }

    // Step 2: Set up context
    PepperHeapContext ctx;
    memset(&ctx, 0, sizeof(ctx));
    ctx.registered_classes = registered;
    ctx.class_count = 0;

    // Get isa mask — use runtime value if available, fallback to known arm64 mask
    if (&objc_debug_isa_class_mask) {
        ctx.isa_mask = objc_debug_isa_class_mask;
    } else {
        ctx.isa_mask = 0x007ffffffffffff8ULL; // arm64 simulator/device
    }

    // Step 3: Enumerate all malloc zones
    vm_address_t *zones = NULL;
    unsigned int zone_count = 0;
    kern_return_t kr = malloc_get_all_zones(mach_task_self(), heap_reader, &zones, &zone_count);

    if (kr == KERN_SUCCESS && zones) {
        for (unsigned int i = 0; i < zone_count; i++) {
            malloc_zone_t *zone = (malloc_zone_t *)zones[i];
            if (!zone) continue;
            malloc_introspection_t *introspect = zone->introspect;
            if (!introspect || !introspect->enumerator) continue;

            // Lock the zone during enumeration to prevent concurrent alloc/free
            if (introspect->force_lock) introspect->force_lock(zone);

            introspect->enumerator(
                mach_task_self(),
                &ctx,
                MALLOC_PTR_IN_USE_RANGE_TYPE,
                (vm_address_t)zone,
                heap_reader,
                heap_recorder
            );

            if (introspect->force_unlock) introspect->force_unlock(zone);
        }
    }

    // Step 4: Convert results, filtering to app-relevant classes
    // System class prefixes to exclude
    const char *exclude_prefixes[] = {
        // Apple frameworks
        "NS", "UI", "CA", "CF", "CG", "AV", "MK", "WK", "SK",
        "_UI", "_NS", "_CA", "_CF", "__NW", "__", "OS_", "PK", "NW",
        "Pepper", "NWHTTP", "Swift.", "_Swift",
        "dispatch_", "xpc_", "os_", "objc_",
        // SwiftUI internal view/modifier types (not app-level)
        "_View", "_Shape", "_Constrained", "_Modified",
        "_Environment", "_Preference", "_Background", "_Overlay",
        "_Padding", "_Frame", "_Flex", "_SafeArea", "_Clip",
        "_Transform", "_Offset", "_Trait", "_Anchor",
        "_Animated", "_Transition", "_Layout",
        "AXMigrat", // Accessibility migration helpers
        NULL
    };

    int result_count = 0;
    PepperHeapEntry *results = (PepperHeapEntry *)malloc(sizeof(PepperHeapEntry) * ctx.class_count);

    for (int i = 0; i < ctx.class_count; i++) {
        if (ctx.class_counts[i] == 0) continue;

        Class cls = (Class)ctx.class_ptrs[i];
        const char *name = class_getName(cls);
        if (!name) continue;

        // Get the short name (after module dot, if present)
        const char *short_name = strrchr(name, '.');
        short_name = short_name ? short_name + 1 : name;

        // Skip system/framework classes (check both full and short name)
        int excluded = 0;
        for (int e = 0; exclude_prefixes[e]; e++) {
            size_t plen = strlen(exclude_prefixes[e]);
            if (strncmp(name, exclude_prefixes[e], plen) == 0 ||
                strncmp(short_name, exclude_prefixes[e], plen) == 0) {
                excluded = 1;
                break;
            }
        }
        if (excluded) continue;

        // Include if name contains a dot (module.ClassName) or matches a prefix
        int included = (strchr(name, '.') != NULL);
        if (!included && filter_prefixes) {
            for (int p = 0; p < prefix_count; p++) {
                if (filter_prefixes[p] && strncmp(name, filter_prefixes[p], strlen(filter_prefixes[p])) == 0) {
                    included = 1;
                    break;
                }
            }
        }
        if (!included) continue;

        results[result_count].class_name = name; // Points into ObjC runtime, valid for process lifetime
        results[result_count].count = ctx.class_counts[i];
        result_count++;
    }

    // Cleanup
    CFRelease(registered);
    free(all_classes);

    *out_entries = results;
    *out_count = result_count;
    return 0;
}

// ---------------------------------------------------------------------------
// pepper_heap_find_instances — collect actual instance pointers for target classes
// ---------------------------------------------------------------------------

#define MAX_FOUND_INSTANCES 256

// Context for instance-collecting scan
typedef struct {
    CFMutableSetRef registered_classes;  // all ObjC classes (for isa validation)
    CFMutableSetRef target_classes;      // classes we want instances of
    const void **found_instances;        // output array
    const void **found_classes;          // parallel array: class ptr for each instance
    int found_count;
    int max_found;
    uint64_t isa_mask;
} PepperFindContext;

// Range recorder that collects instance pointers
static void find_recorder(
    task_t task,
    void *context,
    unsigned type,
    vm_range_t *ranges,
    unsigned count
) {
    if (type != MALLOC_PTR_IN_USE_RANGE_TYPE || !context || !ranges) return;
    PepperFindContext *ctx = (PepperFindContext *)context;

    for (unsigned i = 0; i < count; i++) {
        if (ctx->found_count >= ctx->max_found) return;

        vm_range_t range = ranges[i];
        if (range.size < sizeof(void *)) continue;

        uint64_t isa_raw = *(uint64_t *)range.address;
        uint64_t isa_masked = isa_raw & ctx->isa_mask;

        const void *class_ptr = (const void *)(uintptr_t)isa_masked;
        if (!class_ptr) continue;

        // Must be a registered ObjC class AND one of our targets
        if (CFSetContainsValue(ctx->registered_classes, class_ptr) &&
            CFSetContainsValue(ctx->target_classes, class_ptr)) {
            ctx->found_instances[ctx->found_count] = (const void *)range.address;
            ctx->found_classes[ctx->found_count] = class_ptr;
            ctx->found_count++;
        }
    }
}

/// Find live instances of specific target classes on the heap.
///
/// target_classes: array of Class pointers to search for
/// target_count:   number of entries in target_classes
/// out_instances:  receives malloc'd array of instance pointers (caller frees)
/// out_classes:    receives malloc'd parallel array of class pointers (caller frees)
/// out_count:      receives number of found instances
///
/// Returns 0 on success, -1 on failure.
int pepper_heap_find_instances(
    const void **target_classes,
    int target_count,
    const void ***out_instances,
    const void ***out_classes,
    int *out_count
) {
    *out_instances = NULL;
    *out_classes = NULL;
    *out_count = 0;

    if (!target_classes || target_count == 0) return -1;

    // Build set of all registered ObjC classes
    unsigned int total_class_count = 0;
    Class *all_classes = objc_copyClassList(&total_class_count);
    if (!all_classes || total_class_count == 0) return -1;

    CFMutableSetRef registered = CFSetCreateMutable(NULL, total_class_count, NULL);
    for (unsigned int i = 0; i < total_class_count; i++) {
        CFSetAddValue(registered, (const void *)all_classes[i]);
    }
    free(all_classes);

    // Build set of target classes
    CFMutableSetRef targets = CFSetCreateMutable(NULL, target_count, NULL);
    for (int i = 0; i < target_count; i++) {
        CFSetAddValue(targets, target_classes[i]);
    }

    // Set up context
    PepperFindContext ctx;
    memset(&ctx, 0, sizeof(ctx));
    ctx.registered_classes = registered;
    ctx.target_classes = targets;
    ctx.max_found = MAX_FOUND_INSTANCES;
    ctx.found_instances = (const void **)malloc(sizeof(void *) * MAX_FOUND_INSTANCES);
    ctx.found_classes = (const void **)malloc(sizeof(void *) * MAX_FOUND_INSTANCES);
    ctx.found_count = 0;

    if (&objc_debug_isa_class_mask) {
        ctx.isa_mask = objc_debug_isa_class_mask;
    } else {
        ctx.isa_mask = 0x007ffffffffffff8ULL;
    }

    // Enumerate all malloc zones
    vm_address_t *zones = NULL;
    unsigned int zone_count = 0;
    kern_return_t kr = malloc_get_all_zones(mach_task_self(), heap_reader, &zones, &zone_count);

    if (kr == KERN_SUCCESS && zones) {
        for (unsigned int i = 0; i < zone_count; i++) {
            if (ctx.found_count >= ctx.max_found) break;

            malloc_zone_t *zone = (malloc_zone_t *)zones[i];
            if (!zone) continue;
            malloc_introspection_t *introspect = zone->introspect;
            if (!introspect || !introspect->enumerator) continue;

            if (introspect->force_lock) introspect->force_lock(zone);

            introspect->enumerator(
                mach_task_self(),
                &ctx,
                MALLOC_PTR_IN_USE_RANGE_TYPE,
                (vm_address_t)zone,
                heap_reader,
                find_recorder
            );

            if (introspect->force_unlock) introspect->force_unlock(zone);
        }
    }

    CFRelease(registered);
    CFRelease(targets);

    if (ctx.found_count == 0) {
        free(ctx.found_instances);
        free(ctx.found_classes);
        return 0;
    }

    *out_instances = ctx.found_instances;
    *out_classes = ctx.found_classes;
    *out_count = ctx.found_count;
    return 0;
}

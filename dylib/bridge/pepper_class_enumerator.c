/// Find ObjC runtime subclasses of a given base class using only C-level
/// runtime functions. This avoids Swift type introspection (swift_dynamicCast)
/// which crashes on iOS 26.3 when encountering classes like
/// __NSGenericDeallocHandler that don't implement methodSignatureForSelector:.
///
/// See: BUG-766

#include <objc/runtime.h>
#include <stdlib.h>

/// Find all registered ObjC classes that are subclasses of `base_class`.
///
/// Returns a malloc'd array of Class pointers via `out_classes` (caller frees).
/// Sets `out_count` to the number of results. Returns 0 on success, -1 on failure.
///
/// Uses void* for ABI safety with Swift @_silgen_name bridging.
int pepper_find_subclasses(
    const void *base_class,
    const void ***out_classes,
    int *out_count
) {
    *out_classes = NULL;
    *out_count = 0;

    if (!base_class) return -1;

    unsigned int total = 0;
    Class *all = objc_copyClassList(&total);
    if (!all || total == 0) return -1;

    // Allocate worst-case output buffer
    const void **results = (const void **)malloc(sizeof(void *) * total);
    if (!results) {
        free(all);
        return -1;
    }

    int found = 0;
    for (unsigned int i = 0; i < total; i++) {
        Class cls = all[i];
        if ((const void *)cls == base_class) continue;

        // Walk the superclass chain using the C runtime function.
        // class_getSuperclass is safe — it doesn't trigger Swift metadata
        // initialization or ObjC message forwarding.
        Class ancestor = class_getSuperclass(cls);
        while (ancestor) {
            if ((const void *)ancestor == base_class) {
                results[found++] = (const void *)cls;
                break;
            }
            ancestor = class_getSuperclass(ancestor);
        }
    }

    free(all);

    if (found == 0) {
        free(results);
        return 0;
    }

    *out_classes = results;
    *out_count = found;
    return 0;
}

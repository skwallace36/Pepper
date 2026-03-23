#import "PepperAGExplorer.h"
#import <dlfcn.h>
#import <objc/runtime.h>
#import <os/log.h>
#import <os/signpost.h>

// ---------------------------------------------------------------------------
// AttributeGraph C function typedefs (reverse-engineered from AG headers)
// ---------------------------------------------------------------------------

// Opaque pointer — the core handle for all AG operations.
typedef const void *AGGraphRef;

// AGGraphArchiveJSON: dumps the full attribute graph to a JSON file.
// void AGGraphArchiveJSON(AGGraphRef graph, const char *name);
typedef void (*AGGraphArchiveJSON_fn)(AGGraphRef, const char *);

// AGDebugServerStart: starts AG's built-in debug server.
// void AGDebugServerStart();
typedef void (*AGDebugServerStart_fn)(void);

// AGDebugServerRun: alternative entry point (blocks).
// void AGDebugServerRun();
typedef void (*AGDebugServerRun_fn)(void);

// AGDebugServerCopyURL: returns the debug server URL string.
// char* AGDebugServerCopyURL();
typedef char *(*AGDebugServerCopyURL_fn)(void);

// AG Tracing API
typedef void (*AGGraphSetTrace_fn)(AGGraphRef, int);
typedef bool (*AGGraphIsTracingActive_fn)(AGGraphRef);
typedef void (*AGGraphPrepareTrace_fn)(AGGraphRef);

// Signpost introspection hook (libsystem_trace.dylib)
typedef void (*signpost_hook_fn)(void *);

// ---------------------------------------------------------------------------
// Resolved function pointers (lazily populated)
// ---------------------------------------------------------------------------

static AGGraphArchiveJSON_fn     sAGGraphArchiveJSON     = NULL;
static AGDebugServerStart_fn     sAGDebugServerStart     = NULL;
static AGDebugServerRun_fn       sAGDebugServerRun       = NULL;
static AGDebugServerCopyURL_fn   sAGDebugServerCopyURL   = NULL;
static AGGraphSetTrace_fn        sAGGraphSetTrace        = NULL;
static AGGraphIsTracingActive_fn sAGGraphIsTracingActive = NULL;
static AGGraphPrepareTrace_fn    sAGGraphPrepareTrace    = NULL;
static signpost_hook_fn          sSignpostHook           = NULL;

static BOOL sResolved = NO;
static os_log_t sLog = NULL;

// Signpost event buffer
static NSMutableArray<NSDictionary *> *sSignpostEvents = nil;
static NSLock *sSignpostLock = nil;
static BOOL sSignpostHookInstalled = NO;

// ---------------------------------------------------------------------------
// dlsym resolution
// ---------------------------------------------------------------------------

static void resolveSymbols(void) {
    if (sResolved) return;
    sResolved = YES;

    sLog = os_log_create("com.pepper.control", "ag-explorer");

    // AttributeGraph symbols — the framework is already loaded by SwiftUI
    sAGGraphArchiveJSON     = (AGGraphArchiveJSON_fn)    dlsym(RTLD_DEFAULT, "AGGraphArchiveJSON");
    sAGDebugServerStart     = (AGDebugServerStart_fn)    dlsym(RTLD_DEFAULT, "AGDebugServerStart");
    sAGDebugServerRun       = (AGDebugServerRun_fn)      dlsym(RTLD_DEFAULT, "AGDebugServerRun");
    sAGDebugServerCopyURL   = (AGDebugServerCopyURL_fn)  dlsym(RTLD_DEFAULT, "AGDebugServerCopyURL");
    sAGGraphSetTrace        = (AGGraphSetTrace_fn)       dlsym(RTLD_DEFAULT, "AGGraphSetTrace");
    sAGGraphIsTracingActive = (AGGraphIsTracingActive_fn)dlsym(RTLD_DEFAULT, "AGGraphIsTracingActive");
    sAGGraphPrepareTrace    = (AGGraphPrepareTrace_fn)   dlsym(RTLD_DEFAULT, "AGGraphPrepareTrace");

    // Signpost introspection hook (in libsystem_trace.dylib)
    sSignpostHook = (signpost_hook_fn)dlsym(RTLD_DEFAULT,
                                            "_os_signpost_set_introspection_hook_4Perf");

    os_log(sLog, "AG API resolution complete: "
           "AGGraphArchiveJSON=%{public}s "
           "AGDebugServerStart=%{public}s "
           "AGDebugServerCopyURL=%{public}s "
           "AGGraphSetTrace=%{public}s "
           "AGGraphIsTracingActive=%{public}s "
           "signpost_hook=%{public}s",
           sAGGraphArchiveJSON     ? "YES" : "NO",
           sAGDebugServerStart     ? "YES" : "NO",
           sAGDebugServerCopyURL   ? "YES" : "NO",
           sAGGraphSetTrace        ? "YES" : "NO",
           sAGGraphIsTracingActive ? "YES" : "NO",
           sSignpostHook           ? "YES" : "NO");
}

// ---------------------------------------------------------------------------
// AGGraphRef extraction from _UIHostingView
//
// Path: _UIHostingView -> viewGraph (ViewGraph) -> graph (AGGraphRef)
// The ViewGraph is a Swift object; we access it via ObjC runtime ivar inspection.
// ---------------------------------------------------------------------------

static AGGraphRef extractAGGraphRef(id hostingView) {
    if (!hostingView) return NULL;

    // _UIHostingView has a `viewGraph` property — it's a SwiftUI.ViewGraph instance.
    // We try multiple known ivar/property names since they vary across iOS versions.
    // The ViewGraph object itself contains a `graph` property (the AGGraphRef).

    // Strategy 1: Try direct property access via valueForKey (catches @objc properties)
    @try {
        id viewGraph = [hostingView valueForKey:@"viewGraph"];
        if (viewGraph) {
            os_log(sLog, "Found viewGraph via KVC: %{public}@", [viewGraph class]);

            // Try to get the graph ref from the viewGraph
            @try {
                id graphValue = [viewGraph valueForKey:@"graph"];
                if (graphValue) {
                    os_log(sLog, "Found graph via KVC on viewGraph: %{public}@", [graphValue class]);
                    // The graph ref might be boxed in a Swift struct/class or be an opaque pointer
                    return (__bridge void *)graphValue;
                }
            } @catch (NSException *e) {
                os_log(sLog, "graph KVC failed on viewGraph: %{public}@", e.reason);
            }

            return (__bridge void *)viewGraph;
        }
    } @catch (NSException *e) {
        os_log(sLog, "viewGraph KVC failed: %{public}@", e.reason);
    }

    // Strategy 2: Walk ivars of _UIHostingView looking for ViewGraph-like types
    Class cls = object_getClass(hostingView);
    while (cls && cls != [NSObject class]) {
        unsigned int ivarCount = 0;
        Ivar *ivars = class_copyIvarList(cls, &ivarCount);
        if (ivars) {
            for (unsigned int i = 0; i < ivarCount; i++) {
                const char *name = ivar_getName(ivars[i]);
                const char *typeEnc = ivar_getTypeEncoding(ivars[i]);
                if (name) {
                    NSString *ivarName = @(name);
                    os_log(sLog, "  ivar: %{public}@ type: %{public}s",
                           ivarName, typeEnc ?: "(null)");
                }
            }
            free(ivars);
        }
        cls = class_getSuperclass(cls);
    }

    return NULL;
}

// ---------------------------------------------------------------------------
// Signpost hook callback
// ---------------------------------------------------------------------------

// The signpost introspection hook receives signpost events. The exact signature
// varies by OS version. On iOS 17+, it's approximately:
//   void hook(os_signpost_id_t id, os_log_t log, os_signpost_type_t type,
//             const char *name, const char *format, ...)
// We install a minimal hook that captures event names for SwiftUI subsystem.
//
// NOTE: This is highly experimental. The callback signature is not stable.
// We use a simple wrapper that just records the event.

static void signpostCallback(uint64_t signpost_id,
                              os_log_t log,
                              uint8_t signpost_type,
                              const char *name,
                              const char *fmt) {
    if (!name) return;

    // Filter for SwiftUI signposts only
    NSString *nameStr = @(name);

    NSMutableDictionary *event = [NSMutableDictionary dictionary];
    event[@"signpost_id"] = @(signpost_id);
    event[@"type"] = @(signpost_type);  // 1=begin, 2=end, 0=event
    event[@"name"] = nameStr;
    event[@"timestamp"] = @([[NSDate date] timeIntervalSince1970]);
    if (fmt) {
        event[@"format"] = @(fmt);
    }

    [sSignpostLock lock];
    if (sSignpostEvents.count < 10000) {  // cap buffer
        [sSignpostEvents addObject:[event copy]];
    }
    [sSignpostLock unlock];
}

// ---------------------------------------------------------------------------
// Implementation
// ---------------------------------------------------------------------------

@implementation PepperAGExplorer

+ (NSDictionary<NSString *, NSDictionary *> *)probeAPIs {
    resolveSymbols();

    NSMutableDictionary *report = [NSMutableDictionary dictionary];

    // 1. AGGraphArchiveJSON
    report[@"ag_graph_archive_json"] = @{
        @"resolved": @(sAGGraphArchiveJSON != NULL),
        @"symbol": @"AGGraphArchiveJSON",
        @"notes": sAGGraphArchiveJSON
            ? @"Symbol found. Requires AGGraphRef to call. Use dumpGraphJSON: with a hosting view."
            : @"Symbol not found. AttributeGraph framework may not export this symbol on this iOS version.",
    };

    // 2. AG Debug Server
    NSMutableDictionary *debugServer = [NSMutableDictionary dictionary];
    debugServer[@"start_resolved"] = @(sAGDebugServerStart != NULL);
    debugServer[@"run_resolved"] = @(sAGDebugServerRun != NULL);
    debugServer[@"copy_url_resolved"] = @(sAGDebugServerCopyURL != NULL);
    debugServer[@"symbol_start"] = @"AGDebugServerStart";
    debugServer[@"symbol_copy_url"] = @"AGDebugServerCopyURL";
    if (sAGDebugServerStart) {
        debugServer[@"notes"] = @"Debug server symbols found. Call startDebugServer to attempt activation.";
    } else {
        debugServer[@"notes"] = @"Debug server symbols not found. May require iOS debug runtime.";
    }
    report[@"ag_debug_server"] = debugServer;

    // 3. AG Tracing
    NSMutableDictionary *tracing = [NSMutableDictionary dictionary];
    tracing[@"set_trace_resolved"] = @(sAGGraphSetTrace != NULL);
    tracing[@"is_tracing_resolved"] = @(sAGGraphIsTracingActive != NULL);
    tracing[@"prepare_trace_resolved"] = @(sAGGraphPrepareTrace != NULL);
    tracing[@"symbol_set_trace"] = @"AGGraphSetTrace";
    tracing[@"symbol_is_tracing"] = @"AGGraphIsTracingActive";
    if (sAGGraphSetTrace) {
        tracing[@"notes"] = @"Tracing symbols found. Requires AGGraphRef to activate.";
    } else {
        tracing[@"notes"] = @"Tracing symbols not found on this iOS version.";
    }
    report[@"ag_tracing"] = tracing;

    // 4. Signpost hook
    report[@"signpost_hook"] = @{
        @"resolved": @(sSignpostHook != NULL),
        @"symbol": @"_os_signpost_set_introspection_hook_4Perf",
        @"installed": @(sSignpostHookInstalled),
        @"notes": sSignpostHook
            ? @"Signpost introspection hook found. Call installSignpostHook to capture SwiftUI os_signpost events."
            : @"Signpost hook not found. May be stripped in release builds of libsystem_trace.",
    };

    // 5. Additional AG symbols — scan for other useful exports
    NSMutableArray *additionalSymbols = [NSMutableArray array];
    const char *extraSymbols[] = {
        "AGGraphCreate",
        "AGGraphDestroy",
        "AGGraphGetMainGraph",
        "AGGraphDescription",
        "AGGraphGetTypeID",
        "AGGraphInvalidate",
        "AGGraphSetUpdateCallback",
        "AGGraphObserverCreate",
        "AGAttributeGetValue",
        "AGAttributeSetValue",
        "AGNodeCreate",
        "AGNodeGetValue",
        "AGGraphAddTraceEvent",
        NULL,
    };
    for (int i = 0; extraSymbols[i]; i++) {
        void *sym = dlsym(RTLD_DEFAULT, extraSymbols[i]);
        [additionalSymbols addObject:@{
            @"symbol": @(extraSymbols[i]),
            @"resolved": @(sym != NULL),
        }];
    }
    report[@"additional_symbols"] = @{
        @"symbols": additionalSymbols,
        @"notes": @"Additional AG symbols probed. Available symbols may enable deeper graph inspection.",
    };

    return report;
}

+ (nullable NSString *)startDebugServer {
    resolveSymbols();

    if (!sAGDebugServerStart) {
        return nil;
    }

    @try {
        sAGDebugServerStart();
        os_log(sLog, "AGDebugServerStart called successfully");

        if (sAGDebugServerCopyURL) {
            char *url = sAGDebugServerCopyURL();
            if (url) {
                NSString *urlStr = @(url);
                free(url);
                os_log(sLog, "AG debug server URL: %{public}@", urlStr);
                return urlStr;
            }
        }

        return @"started (URL unavailable)";
    } @catch (NSException *e) {
        os_log(sLog, "AGDebugServerStart threw: %{public}@", e.reason);
        return nil;
    }
}

+ (nullable NSString *)dumpGraphJSON:(id)hostingView name:(NSString *)name {
    resolveSymbols();

    if (!sAGGraphArchiveJSON) {
        return nil;
    }

    AGGraphRef graphRef = extractAGGraphRef(hostingView);
    if (!graphRef) {
        os_log(sLog, "Failed to extract AGGraphRef from hosting view");
        return nil;
    }

    @try {
        // AGGraphArchiveJSON writes to the app's Documents or tmp directory
        NSString *tmpDir = NSTemporaryDirectory();
        NSString *baseName = name ?: @"pepper_ag_dump";

        sAGGraphArchiveJSON(graphRef, [baseName UTF8String]);

        // Look for the output file — AG typically writes to the current directory
        // or a path derived from the name argument
        NSArray *searchPaths = @[
            [tmpDir stringByAppendingPathComponent:
                [baseName stringByAppendingString:@".json"]],
            [NSString stringWithFormat:@"%@.json", baseName],
            [NSHomeDirectory() stringByAppendingPathComponent:
                [baseName stringByAppendingString:@".json"]],
        ];

        for (NSString *path in searchPaths) {
            if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
                os_log(sLog, "AG graph dumped to: %{public}@", path);
                return path;
            }
        }

        os_log(sLog, "AGGraphArchiveJSON called but output file not found in expected locations");
        return nil;
    } @catch (NSException *e) {
        os_log(sLog, "AGGraphArchiveJSON threw: %{public}@", e.reason);
        return nil;
    }
}

+ (BOOL)installSignpostHook {
    resolveSymbols();

    if (!sSignpostHook) {
        return NO;
    }

    if (sSignpostHookInstalled) {
        return YES;  // already installed
    }

    if (!sSignpostEvents) {
        sSignpostEvents = [NSMutableArray array];
        sSignpostLock = [[NSLock alloc] init];
    }

    @try {
        // NOTE: The exact calling convention for this hook is not documented.
        // On iOS 17+, the function signature is believed to be:
        //   void _os_signpost_set_introspection_hook_4Perf(void (*hook)(...))
        // We pass our callback; if the signature mismatches, this may crash.
        // In a research context, this is acceptable — we document the result.
        sSignpostHook((void *)signpostCallback);
        sSignpostHookInstalled = YES;
        os_log(sLog, "Signpost introspection hook installed");
        return YES;
    } @catch (NSException *e) {
        os_log(sLog, "Signpost hook installation threw: %{public}@", e.reason);
        return NO;
    }
}

+ (NSArray<NSDictionary *> *)drainSignpostEvents {
    if (!sSignpostLock) return @[];

    [sSignpostLock lock];
    NSArray *events = [sSignpostEvents copy];
    [sSignpostEvents removeAllObjects];
    [sSignpostLock unlock];

    return events;
}

+ (nullable void *)extractGraphRef:(id)hostingView {
    resolveSymbols();
    return (void *)extractAGGraphRef(hostingView);
}

@end

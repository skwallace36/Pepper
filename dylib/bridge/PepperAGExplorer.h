#ifndef PepperAGExplorer_h
#define PepperAGExplorer_h

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Probes SwiftUI's private AttributeGraph APIs via dlsym to determine which
/// are callable from an injected dylib. Research-grade — APIs are undocumented
/// and may change between iOS versions.
@interface PepperAGExplorer : NSObject

/// Probe all known AG APIs and return a report of what's available.
/// Returns a dictionary with keys: ag_graph_archive_json, ag_debug_server,
/// ag_tracing, signpost_hook — each mapping to a status dict.
+ (NSDictionary<NSString *, NSDictionary *> *)probeAPIs;

/// Attempt to start the AG debug server. Returns the URL string if successful, nil otherwise.
+ (nullable NSString *)startDebugServer;

/// Attempt to dump the attribute graph to JSON via AGGraphArchiveJSON.
/// Returns the file path written to, or nil on failure.
/// Requires a _UIHostingView to extract the AGGraphRef from.
+ (nullable NSString *)dumpGraphJSON:(id)hostingView name:(NSString *)name;

/// Attempt to install a signpost introspection hook for SwiftUI events.
/// Returns YES if the hook function was found and installed.
+ (BOOL)installSignpostHook;

/// Returns collected signpost events since last call (drains the buffer).
+ (NSArray<NSDictionary *> *)drainSignpostEvents;

/// Attempt to extract the AGGraphRef from a _UIHostingView.
/// Returns the pointer as a void*, or NULL if extraction fails.
+ (nullable void *)extractGraphRef:(id)hostingView;

@end

NS_ASSUME_NONNULL_END

#endif /* PepperAGExplorer_h */

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Generic ObjC method hooking engine. Intercepts any ObjC method call,
/// logs invocations, and calls through to the original implementation.
/// Uses imp_implementationWithBlock for common signatures, falling back
/// to forwardInvocation: for complex ones.
@interface PepperMethodHookEngine : NSObject

/// Install a hook on a class method. Returns hook ID on success, nil on error.
/// Error description is written to *outError if non-NULL.
+ (nullable NSString *)installOnClass:(NSString *)className
                               method:(NSString *)methodName
                          classMethod:(BOOL)isClassMethod
                                error:(NSString *_Nullable *_Nullable)outError;

/// Remove a specific hook by ID. Returns YES if found and removed.
+ (BOOL)removeHook:(NSString *)hookId;

/// Remove all installed hooks (restores original implementations).
+ (void)removeAll;

/// List all installed hooks as dictionaries.
+ (NSArray<NSDictionary *> *)listHooks;

/// Get call log entries. If hookId is nil, returns entries from all hooks.
+ (NSArray<NSDictionary *> *)callLogForHook:(nullable NSString *)hookId
                                      limit:(NSInteger)limit;

/// Clear call log. If hookId is nil, clears all logs.
+ (void)clearLog:(nullable NSString *)hookId;

/// Total number of installed hooks.
+ (NSInteger)hookCount;

@end

NS_ASSUME_NONNULL_END

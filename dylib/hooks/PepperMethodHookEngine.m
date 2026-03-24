#import "PepperMethodHookEngine.h"
#import <objc/runtime.h>
#import <os/log.h>

// ---------------------------------------------------------------------------
// Hook entry — stores state for one installed hook
// ---------------------------------------------------------------------------

@interface PepperHookEntry : NSObject
@property (nonatomic, copy) NSString *hookId;
@property (nonatomic, copy) NSString *className;
@property (nonatomic, copy) NSString *methodName;
@property (nonatomic, assign) BOOL isClassMethod;
@property (nonatomic, assign) Class targetClass;
@property (nonatomic, assign) SEL selector;
@property (nonatomic, assign) IMP originalIMP;
@property (nonatomic, assign) NSInteger callCount;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *callLog;
@property (nonatomic, strong) NSDate *installedAt;
@end

@implementation PepperHookEntry
- (instancetype)init {
    self = [super init];
    if (self) {
        _callLog = [NSMutableArray new];
        _callCount = 0;
        _installedAt = [NSDate date];
    }
    return self;
}
@end

// ---------------------------------------------------------------------------
// Hook registry
// ---------------------------------------------------------------------------

static NSMutableDictionary<NSString *, PepperHookEntry *> *sHookRegistry = nil;
static NSInteger sNextHookId = 1;
static const NSInteger kMaxCallLog = 200;  // per hook
static os_log_t sLog = NULL;

// Classes that must never be hooked — hooking these causes crashes, infinite
// recursion, or runtime corruption (they sit on every call path in ObjC).
static NSSet<NSString *> *sDangerousClasses = nil;

static void ensureInit(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sHookRegistry = [NSMutableDictionary new];
        sLog = os_log_create("com.pepper.control", "hook");
        sDangerousClasses = [NSSet setWithArray:@[
            // Foundation roots — on every call path
            @"NSObject", @"NSProxy",
            // Strings — used by logging itself (infinite recursion)
            @"NSString", @"NSMutableString", @"__NSCFString", @"__NSCFConstantString",
            @"NSTaggedPointerString",
            // Collections — mutated by the hook engine
            @"NSArray", @"NSMutableArray", @"NSDictionary", @"NSMutableDictionary",
            @"NSSet", @"NSMutableSet",
            @"__NSSingleObjectArrayI", @"__NSArrayI", @"__NSArrayM",
            @"__NSDictionaryI", @"__NSDictionaryM",
            // Numbers — used in call log dictionaries
            @"NSNumber", @"NSValue", @"__NSCFNumber", @"__NSCFBoolean",
            // Memory management / runtime internals
            @"NSAutoreleasePool", @"NSMethodSignature", @"NSInvocation",
            @"NSBlock", @"__NSGlobalBlock__", @"__NSStackBlock__", @"__NSMallocBlock__",
            // UIKit base classes — affect all UI
            @"UIView", @"UIResponder", @"UIViewController",
            @"UIScrollView", @"UIWindow", @"UIApplication",
        ]];
    });
}

// ---------------------------------------------------------------------------
// Safe description — catches exceptions, truncates huge strings
// ---------------------------------------------------------------------------

static const NSUInteger kMaxDescriptionLength = 500;

static NSString *safeDescription(id value) {
    @try {
        NSString *desc = [value description];
        if (!desc) return @"(nil)";
        if (desc.length > kMaxDescriptionLength) {
            return [NSString stringWithFormat:@"%@…(%lu chars)",
                    [desc substringToIndex:kMaxDescriptionLength], (unsigned long)desc.length];
        }
        return desc;
    } @catch (NSException *e) {
        return [NSString stringWithFormat:@"<%@:%p (description threw %@)>",
                NSStringFromClass([value class]), value, e.name];
    }
}

// ---------------------------------------------------------------------------
// Record a call
// ---------------------------------------------------------------------------

static void recordCall(PepperHookEntry *entry, id receiver, NSArray *argDescriptions) {
    @synchronized (entry) {
        entry.callCount++;
        NSDictionary *record = @{
            @"hook_id": entry.hookId,
            @"class": entry.className,
            @"method": entry.methodName,
            @"receiver": safeDescription(receiver),
            @"receiver_class": NSStringFromClass([receiver class]) ?: @"?",
            @"args": argDescriptions ?: @[],
            @"timestamp": @([[NSDate date] timeIntervalSince1970]),
            @"call_number": @(entry.callCount),
        };
        [entry.callLog addObject:record];
        // Trim to circular buffer size
        while (entry.callLog.count > kMaxCallLog) {
            [entry.callLog removeObjectAtIndex:0];
        }
    }
}

// ---------------------------------------------------------------------------
// Type encoding helpers
// ---------------------------------------------------------------------------

typedef struct {
    char returnType;      // 'v' void, '@' object, 'B' BOOL, 'q' int64, 'i' int32, 'd' double, 'f' float, etc.
    int argCount;         // number of args after self + _cmd
    char argTypes[8];     // type of each arg (max 8)
} MethodSignatureInfo;

static MethodSignatureInfo parseTypeEncoding(const char *encoding) {
    MethodSignatureInfo info = {0};
    if (!encoding || !encoding[0]) return info;

    // Return type is first char (skip qualifiers like r, n, N, o, O, R, V)
    const char *p = encoding;
    while (*p == 'r' || *p == 'n' || *p == 'N' || *p == 'o' || *p == 'O' || *p == 'R' || *p == 'V') p++;
    info.returnType = *p;

    // Count method arguments using NSMethodSignature
    // (simpler than manually parsing the encoding)
    NSMethodSignature *sig = [NSMethodSignature signatureWithObjCTypes:encoding];
    if (!sig) return info;

    // numberOfArguments includes self + _cmd
    NSInteger totalArgs = [sig numberOfArguments];
    info.argCount = (int)(totalArgs - 2);  // subtract self + _cmd

    for (int i = 0; i < info.argCount && i < 8; i++) {
        const char *argType = [sig getArgumentTypeAtIndex:i + 2];
        if (argType) {
            // Skip qualifiers
            while (*argType == 'r' || *argType == 'n' || *argType == 'N' || *argType == 'o' || *argType == 'O' || *argType == 'R' || *argType == 'V') argType++;
            info.argTypes[i] = *argType;
        }
    }

    // Normalize: treat block args (@?) as object args (@).
    // Blocks are ObjC objects and can be passed/described as id.
    for (int i = 0; i < info.argCount && i < 8; i++) {
        // Block type encoding is '@' followed by '?' — our single-char parse already gets '@'
        // but let's be explicit. Also treat '#' (Class) as '@' for simplicity.
        if (info.argTypes[i] == '#') info.argTypes[i] = '@';
    }
    return info;
}

// ---------------------------------------------------------------------------
// Describe an argument value for logging
// ---------------------------------------------------------------------------

static NSString *describeArg(char type, id value) {
    if (!value || value == [NSNull null]) return @"(nil)";
    switch (type) {
        case '@': return safeDescription(value);
        default:  return [NSString stringWithFormat:@"%@", value];
    }
}

// ---------------------------------------------------------------------------
// Block-based IMP creation for common signatures
// ---------------------------------------------------------------------------

// We create blocks matching the method signature, capturing the hook entry
// and original IMP. The block logs the call, then calls through to the original.
//
// Supported: void/obj return × 0-3 object args. For other signatures,
// we use a simpler approach that just logs the call count without args.

static IMP createHookIMP(PepperHookEntry *entry, MethodSignatureInfo sig) {
    IMP origIMP = entry.originalIMP;
    SEL sel = entry.selector;
    __weak PepperHookEntry *weakEntry = entry;

    // --- void return ---
    if (sig.returnType == 'v') {
        if (sig.argCount == 0) {
            id block = ^(id self_) {
                PepperHookEntry *e = weakEntry;
                if (e) recordCall(e, self_, @[]);
                ((void(*)(id, SEL))origIMP)(self_, sel);
            };
            return imp_implementationWithBlock(block);
        }
        if (sig.argCount == 1 && sig.argTypes[0] == '@') {
            id block = ^(id self_, id a1) {
                PepperHookEntry *e = weakEntry;
                if (e) recordCall(e, self_, @[describeArg('@', a1)]);
                ((void(*)(id, SEL, id))origIMP)(self_, sel, a1);
            };
            return imp_implementationWithBlock(block);
        }
        if (sig.argCount == 2 && sig.argTypes[0] == '@' && sig.argTypes[1] == '@') {
            id block = ^(id self_, id a1, id a2) {
                PepperHookEntry *e = weakEntry;
                if (e) recordCall(e, self_, @[describeArg('@', a1), describeArg('@', a2)]);
                ((void(*)(id, SEL, id, id))origIMP)(self_, sel, a1, a2);
            };
            return imp_implementationWithBlock(block);
        }
        if (sig.argCount == 3 && sig.argTypes[0] == '@' && sig.argTypes[1] == '@' && sig.argTypes[2] == '@') {
            id block = ^(id self_, id a1, id a2, id a3) {
                PepperHookEntry *e = weakEntry;
                if (e) recordCall(e, self_, @[describeArg('@', a1), describeArg('@', a2), describeArg('@', a3)]);
                ((void(*)(id, SEL, id, id, id))origIMP)(self_, sel, a1, a2, a3);
            };
            return imp_implementationWithBlock(block);
        }
        // void return with BOOL arg (common: viewDidAppear:, etc.)
        if (sig.argCount == 1 && (sig.argTypes[0] == 'B' || sig.argTypes[0] == 'c')) {
            id block = ^(id self_, BOOL a1) {
                PepperHookEntry *e = weakEntry;
                if (e) recordCall(e, self_, @[a1 ? @"YES" : @"NO"]);
                ((void(*)(id, SEL, BOOL))origIMP)(self_, sel, a1);
            };
            return imp_implementationWithBlock(block);
        }
        // void + object + BOOL (common: setObject:animated:, etc.)
        if (sig.argCount == 2 && sig.argTypes[0] == '@' && (sig.argTypes[1] == 'B' || sig.argTypes[1] == 'c')) {
            id block = ^(id self_, id a1, BOOL a2) {
                PepperHookEntry *e = weakEntry;
                if (e) recordCall(e, self_, @[describeArg('@', a1), a2 ? @"YES" : @"NO"]);
                ((void(*)(id, SEL, id, BOOL))origIMP)(self_, sel, a1, a2);
            };
            return imp_implementationWithBlock(block);
        }
        // void + object + BOOL + object (common: presentViewController:animated:completion:)
        if (sig.argCount == 3 && sig.argTypes[0] == '@' && (sig.argTypes[1] == 'B' || sig.argTypes[1] == 'c') && sig.argTypes[2] == '@') {
            id block = ^(id self_, id a1, BOOL a2, id a3) {
                PepperHookEntry *e = weakEntry;
                if (e) recordCall(e, self_, @[describeArg('@', a1), a2 ? @"YES" : @"NO", describeArg('@', a3)]);
                ((void(*)(id, SEL, id, BOOL, id))origIMP)(self_, sel, a1, a2, a3);
            };
            return imp_implementationWithBlock(block);
        }
        // void + object + object + BOOL
        if (sig.argCount == 3 && sig.argTypes[0] == '@' && sig.argTypes[1] == '@' && (sig.argTypes[2] == 'B' || sig.argTypes[2] == 'c')) {
            id block = ^(id self_, id a1, id a2, BOOL a3) {
                PepperHookEntry *e = weakEntry;
                if (e) recordCall(e, self_, @[describeArg('@', a1), describeArg('@', a2), a3 ? @"YES" : @"NO"]);
                ((void(*)(id, SEL, id, id, BOOL))origIMP)(self_, sel, a1, a2, a3);
            };
            return imp_implementationWithBlock(block);
        }
    }

    // --- object return ---
    if (sig.returnType == '@') {
        if (sig.argCount == 0) {
            id block = ^id(id self_) {
                PepperHookEntry *e = weakEntry;
                if (e) recordCall(e, self_, @[]);
                return ((id(*)(id, SEL))origIMP)(self_, sel);
            };
            return imp_implementationWithBlock(block);
        }
        if (sig.argCount == 1 && sig.argTypes[0] == '@') {
            id block = ^id(id self_, id a1) {
                PepperHookEntry *e = weakEntry;
                if (e) recordCall(e, self_, @[describeArg('@', a1)]);
                return ((id(*)(id, SEL, id))origIMP)(self_, sel, a1);
            };
            return imp_implementationWithBlock(block);
        }
        if (sig.argCount == 2 && sig.argTypes[0] == '@' && sig.argTypes[1] == '@') {
            id block = ^id(id self_, id a1, id a2) {
                PepperHookEntry *e = weakEntry;
                if (e) recordCall(e, self_, @[describeArg('@', a1), describeArg('@', a2)]);
                return ((id(*)(id, SEL, id, id))origIMP)(self_, sel, a1, a2);
            };
            return imp_implementationWithBlock(block);
        }
        // object return + BOOL arg (common: popViewControllerAnimated:)
        if (sig.argCount == 1 && (sig.argTypes[0] == 'B' || sig.argTypes[0] == 'c')) {
            id block = ^id(id self_, BOOL a1) {
                PepperHookEntry *e = weakEntry;
                if (e) recordCall(e, self_, @[a1 ? @"YES" : @"NO"]);
                return ((id(*)(id, SEL, BOOL))origIMP)(self_, sel, a1);
            };
            return imp_implementationWithBlock(block);
        }
    }

    // --- BOOL return ---
    if (sig.returnType == 'B' || sig.returnType == 'c') {
        if (sig.argCount == 0) {
            id block = ^BOOL(id self_) {
                PepperHookEntry *e = weakEntry;
                if (e) recordCall(e, self_, @[]);
                return ((BOOL(*)(id, SEL))origIMP)(self_, sel);
            };
            return imp_implementationWithBlock(block);
        }
        if (sig.argCount == 1 && sig.argTypes[0] == '@') {
            id block = ^BOOL(id self_, id a1) {
                PepperHookEntry *e = weakEntry;
                if (e) recordCall(e, self_, @[describeArg('@', a1)]);
                return ((BOOL(*)(id, SEL, id))origIMP)(self_, sel, a1);
            };
            return imp_implementationWithBlock(block);
        }
    }

    // --- Fallback: log-only wrapper for unsupported signatures ---
    // We can still count calls even if we can't capture args.
    // Use a void/0-arg block that calls the original IMP.
    // NOTE: This only works safely for void-return methods with no args or
    // where arg forwarding isn't needed. For complex signatures we return NULL
    // and the caller should report "unsupported signature".
    return NULL;
}

// ---------------------------------------------------------------------------
// Implementation
// ---------------------------------------------------------------------------

@implementation PepperMethodHookEngine

+ (nullable NSString *)installOnClass:(NSString *)className
                               method:(NSString *)methodName
                          classMethod:(BOOL)isClassMethod
                                error:(NSString *_Nullable *_Nullable)outError {
    ensureInit();

    // Block hooking system classes — crashes, infinite recursion, or runtime corruption
    if ([sDangerousClasses containsObject:className]) {
        if (outError) *outError = [NSString stringWithFormat:
            @"Refused: %@ is a system class. Hooking it would crash the app or the hook engine itself. "
            @"Only hook app-specific or third-party classes.", className];
        return nil;
    }

    // Resolve class
    Class cls = NSClassFromString(className);
    if (!cls) {
        if (outError) *outError = [NSString stringWithFormat:@"Class not found: %@", className];
        return nil;
    }

    // For class methods, operate on the metaclass
    Class targetClass = isClassMethod ? object_getClass(cls) : cls;

    // Resolve selector
    SEL sel = NSSelectorFromString(methodName);
    Method method = class_getInstanceMethod(targetClass, sel);
    if (!method) {
        if (outError) *outError = [NSString stringWithFormat:@"Method not found: %@%@.%@",
                                   isClassMethod ? @"+" : @"-", className, methodName];
        return nil;
    }

    // Parse type encoding (safe to do outside lock — pure computation)
    const char *encoding = method_getTypeEncoding(method);
    MethodSignatureInfo sig = parseTypeEncoding(encoding);

    // Synchronized: duplicate check + IMP swap + registry insert must be atomic
    // to prevent two threads installing the same hook concurrently.
    @synchronized (sHookRegistry) {
        // Check for duplicate hooks
        for (PepperHookEntry *existing in sHookRegistry.allValues) {
            if (existing.targetClass == targetClass && sel_isEqual(existing.selector, sel)) {
                if (outError) *outError = [NSString stringWithFormat:@"Already hooked: %@.%@ (id: %@)",
                                           className, methodName, existing.hookId];
                return nil;
            }
        }

        // Create hook entry
        PepperHookEntry *entry = [PepperHookEntry new];
        entry.hookId = [NSString stringWithFormat:@"hook_%ld", (long)sNextHookId++];
        entry.className = className;
        entry.methodName = methodName;
        entry.isClassMethod = isClassMethod;
        entry.targetClass = targetClass;
        entry.selector = sel;
        entry.originalIMP = method_getImplementation(method);

        // Create replacement IMP
        IMP hookIMP = createHookIMP(entry, sig);
        if (!hookIMP) {
            if (outError) *outError = [NSString stringWithFormat:
                @"Unsupported method signature for %@.%@ (encoding: %s). "
                @"Supported: void/object/BOOL return with 0-3 object args or 1 BOOL arg.",
                className, methodName, encoding ?: "(null)"];
            return nil;
        }

        // Install the hook
        method_setImplementation(method, hookIMP);
        sHookRegistry[entry.hookId] = entry;

        os_log(sLog, "Installed hook %{public}@ on %{public}@%{public}@.%{public}@",
               entry.hookId, isClassMethod ? @"+" : @"-", className, methodName);

        return entry.hookId;
    }
}

+ (BOOL)removeHook:(NSString *)hookId {
    ensureInit();

    @synchronized (sHookRegistry) {
        PepperHookEntry *entry = sHookRegistry[hookId];
        if (!entry) return NO;

        // Restore original implementation
        Method method = class_getInstanceMethod(entry.targetClass, entry.selector);
        if (method) {
            method_setImplementation(method, entry.originalIMP);
        }

        [sHookRegistry removeObjectForKey:hookId];
        os_log(sLog, "Removed hook %{public}@", hookId);
        return YES;
    }
}

+ (void)removeAll {
    ensureInit();

    @synchronized (sHookRegistry) {
        for (NSString *hookId in sHookRegistry.allKeys.copy) {
            PepperHookEntry *entry = sHookRegistry[hookId];
            if (!entry) continue;
            Method method = class_getInstanceMethod(entry.targetClass, entry.selector);
            if (method) {
                method_setImplementation(method, entry.originalIMP);
            }
            [sHookRegistry removeObjectForKey:hookId];
            os_log(sLog, "Removed hook %{public}@", hookId);
        }
    }
}

+ (NSArray<NSDictionary *> *)listHooks {
    ensureInit();

    NSMutableArray *result = [NSMutableArray new];
    @synchronized (sHookRegistry) {
        for (PepperHookEntry *entry in sHookRegistry.allValues) {
            @synchronized (entry) {
                [result addObject:@{
                    @"id": entry.hookId,
                    @"class": entry.className,
                    @"method": entry.methodName,
                    @"class_method": @(entry.isClassMethod),
                    @"call_count": @(entry.callCount),
                    @"installed_at": @([entry.installedAt timeIntervalSince1970]),
                }];
            }
        }
    }
    return result;
}

+ (NSArray<NSDictionary *> *)callLogForHook:(nullable NSString *)hookId
                                      limit:(NSInteger)limit {
    ensureInit();

    NSMutableArray *result = [NSMutableArray new];

    @synchronized (sHookRegistry) {
        if (hookId) {
            PepperHookEntry *entry = sHookRegistry[hookId];
            if (entry) {
                @synchronized (entry) {
                    NSInteger start = entry.callLog.count > limit ? entry.callLog.count - limit : 0;
                    for (NSInteger i = entry.callLog.count - 1; i >= start; i--) {
                        [result addObject:entry.callLog[i]];
                    }
                }
            }
        } else {
            // All hooks — merge and sort by timestamp desc
            for (PepperHookEntry *entry in sHookRegistry.allValues) {
                @synchronized (entry) {
                    [result addObjectsFromArray:entry.callLog];
                }
            }
        }
    }

    if (!hookId) {
        [result sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            return [b[@"timestamp"] compare:a[@"timestamp"]];
        }];
        if (result.count > (NSUInteger)limit) {
            [result removeObjectsInRange:NSMakeRange(limit, result.count - limit)];
        }
    }

    return result;
}

+ (void)clearLog:(nullable NSString *)hookId {
    ensureInit();

    @synchronized (sHookRegistry) {
        if (hookId) {
            PepperHookEntry *entry = sHookRegistry[hookId];
            if (entry) {
                @synchronized (entry) {
                    [entry.callLog removeAllObjects];
                    entry.callCount = 0;
                }
            }
        } else {
            for (PepperHookEntry *entry in sHookRegistry.allValues) {
                @synchronized (entry) {
                    [entry.callLog removeAllObjects];
                    entry.callCount = 0;
                }
            }
        }
    }
}

+ (NSInteger)hookCount {
    ensureInit();
    @synchronized (sHookRegistry) {
        return sHookRegistry.count;
    }
}

@end

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Catches ObjC exceptions (NSException) that Swift can't catch natively.
/// Used for NSPredicate format validation where bad format strings raise NSException.
@interface PepperObjCExceptionCatcher : NSObject
+ (void)tryBlock:(void(^)(void))tryBlock catchBlock:(void(^)(NSException *))catchBlock;
@end

NS_ASSUME_NONNULL_END

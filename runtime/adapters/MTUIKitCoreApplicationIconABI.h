#import <Foundation/Foundation.h>

#import <objc/runtime.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const
    MTUIKitCoreApplicationIconExpectedImageUUID;
FOUNDATION_EXPORT BOOL MTUIKitCoreApplicationIconClassMatchesExpectedImage(
    Class _Nullable runtimeClass);
FOUNDATION_EXPORT BOOL
    MTUIKitCoreApplicationIconImplementationMatchesExpectedImage(
        IMP _Nullable implementation);

NS_ASSUME_NONNULL_END

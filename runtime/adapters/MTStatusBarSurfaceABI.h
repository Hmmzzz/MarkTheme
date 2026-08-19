#import <Foundation/Foundation.h>

#import <objc/runtime.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const
    MTSystemStatusUIStatusBarExpectedImageUUID;
FOUNDATION_EXPORT NSString *const
    MTUIKitCoreStatusBarWindowExpectedImageUUID;

FOUNDATION_EXPORT BOOL MTSystemStatusUIStatusBarClassMatchesExpectedImage(
    Class _Nullable runtimeClass);
FOUNDATION_EXPORT BOOL
    MTSystemStatusUIStatusBarImplementationMatchesExpectedImage(
        IMP _Nullable implementation);
FOUNDATION_EXPORT BOOL
    MTUIKitCoreStatusBarWindowImplementationMatchesExpectedImage(
        IMP _Nullable implementation);

NS_ASSUME_NONNULL_END

#import <Foundation/Foundation.h>

#import <objc/runtime.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT BOOL MTSearchUIClassMatchesExpectedImage(
    Class _Nullable runtimeClass);
FOUNDATION_EXPORT BOOL MTSearchUIImplementationMatchesExpectedImage(
    IMP _Nullable implementation);

NS_ASSUME_NONNULL_END

#import <Foundation/Foundation.h>

#import <objc/runtime.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT BOOL MTSpringBoardHomeClassMatchesExpectedImage(
    Class _Nullable runtimeClass);
FOUNDATION_EXPORT BOOL MTSpringBoardHomeImplementationMatchesExpectedImage(
    IMP _Nullable implementation);
FOUNDATION_EXPORT BOOL MTRuntimeClassIsSubclassOfClass(
    Class _Nullable runtimeClass,
    Class _Nullable expectedClass);

NS_ASSUME_NONNULL_END

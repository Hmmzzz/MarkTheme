#import <Foundation/Foundation.h>

#import <objc/runtime.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const MTPreferencesExpectedImageUUID;

FOUNDATION_EXPORT BOOL MTPreferencesClassMatchesExpectedImage(
    Class _Nullable runtimeClass);
FOUNDATION_EXPORT BOOL MTPreferencesImplementationMatchesExpectedImage(
    IMP _Nullable implementation);

NS_ASSUME_NONNULL_END

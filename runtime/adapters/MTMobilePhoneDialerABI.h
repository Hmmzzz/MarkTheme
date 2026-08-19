#import <Foundation/Foundation.h>

#import <objc/runtime.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const MTMobilePhoneDialerExpectedImageUUID;
FOUNDATION_EXPORT NSString *const MTTelephonyUIDialerExpectedImageUUID;

FOUNDATION_EXPORT BOOL MTMobilePhoneDialerClassMatchesExpectedImage(
    Class _Nullable runtimeClass);
FOUNDATION_EXPORT BOOL MTMobilePhoneDialerImplementationMatchesExpectedImage(
    IMP _Nullable implementation);
FOUNDATION_EXPORT BOOL MTTelephonyUIDialerClassMatchesExpectedImage(
    Class _Nullable runtimeClass);
FOUNDATION_EXPORT BOOL MTTelephonyUIDialerImplementationMatchesExpectedImage(
    IMP _Nullable implementation);

NS_ASSUME_NONNULL_END

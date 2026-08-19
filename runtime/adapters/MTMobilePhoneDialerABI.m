#import "MTMobilePhoneDialerABI.h"

#import "MTRuntimeImageABI.h"

static const char *const MTMobilePhoneDialerExpectedImagePath =
    "/Applications/MobilePhone.app/MobilePhone";
static const char *const MTTelephonyUIDialerExpectedImagePath =
    "/System/Library/PrivateFrameworks/TelephonyUI.framework/TelephonyUI";

BOOL MTMobilePhoneDialerClassMatchesExpectedImage(Class runtimeClass) {
    return MTRuntimeClassMatchesImagePath(
        runtimeClass, MTMobilePhoneDialerExpectedImagePath);
}

BOOL MTMobilePhoneDialerImplementationMatchesExpectedImage(
    IMP implementation) {
    return MTRuntimeImplementationMatchesImage(
        implementation, MTMobilePhoneDialerExpectedImagePath);
}

BOOL MTTelephonyUIDialerClassMatchesExpectedImage(Class runtimeClass) {
    return MTRuntimeClassMatchesImagePath(
        runtimeClass, MTTelephonyUIDialerExpectedImagePath);
}

BOOL MTTelephonyUIDialerImplementationMatchesExpectedImage(
    IMP implementation) {
    return MTRuntimeImplementationMatchesImage(
        implementation, MTTelephonyUIDialerExpectedImagePath);
}

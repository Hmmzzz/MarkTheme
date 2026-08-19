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

// Coexistence: any resolvable implementation — Apple's original, another
// Apple image, or another tweak's chained Hook — stays hookable so other
// tweaks keep working; the exact-image match is provenance only.
BOOL MTMobilePhoneDialerImplementationMatchesExpectedImage(
    IMP implementation) {
    return MTRuntimeImplementationMatchesImage(
               implementation, MTMobilePhoneDialerExpectedImagePath) ||
        MTRuntimeImplementationResolves(implementation);
}

BOOL MTTelephonyUIDialerClassMatchesExpectedImage(Class runtimeClass) {
    return MTRuntimeClassMatchesImagePath(
        runtimeClass, MTTelephonyUIDialerExpectedImagePath);
}

BOOL MTTelephonyUIDialerImplementationMatchesExpectedImage(
    IMP implementation) {
    return MTRuntimeImplementationMatchesImage(
               implementation, MTTelephonyUIDialerExpectedImagePath) ||
        MTRuntimeImplementationResolves(implementation);
}

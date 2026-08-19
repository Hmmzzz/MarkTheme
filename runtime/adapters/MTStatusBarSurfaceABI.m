#import "MTStatusBarSurfaceABI.h"

#import "MTRuntimeImageABI.h"

static const char *const MTSystemStatusUIStatusBarExpectedImagePath =
    "/System/Library/PrivateFrameworks/SystemStatusUI.framework/"
    "SystemStatusUI";
static const char *const MTUIKitCoreStatusBarWindowExpectedImagePath =
    "/System/Library/PrivateFrameworks/UIKitCore.framework/UIKitCore";

BOOL MTSystemStatusUIStatusBarClassMatchesExpectedImage(
    Class runtimeClass) {
    return MTRuntimeClassMatchesImagePath(
        runtimeClass, MTSystemStatusUIStatusBarExpectedImagePath);
}

// Coexistence: any resolvable implementation — Apple's original, another
// Apple image, or another tweak's chained Hook — stays hookable so other
// tweaks keep working; the exact-image match is provenance only.
BOOL MTSystemStatusUIStatusBarImplementationMatchesExpectedImage(
    IMP implementation) {
    return MTRuntimeImplementationMatchesImage(
               implementation, MTSystemStatusUIStatusBarExpectedImagePath) ||
        MTRuntimeImplementationResolves(implementation);
}

BOOL MTUIKitCoreStatusBarWindowImplementationMatchesExpectedImage(
    IMP implementation) {
    return MTRuntimeImplementationMatchesImage(
               implementation, MTUIKitCoreStatusBarWindowExpectedImagePath) ||
        MTRuntimeImplementationResolves(implementation);
}

#import "MTUIKitCoreApplicationIconABI.h"

#import "MTRuntimeImageABI.h"

static const char *const MTUIKitCoreApplicationIconExpectedImagePath =
    "/System/Library/PrivateFrameworks/UIKitCore.framework/UIKitCore";

BOOL MTUIKitCoreApplicationIconClassMatchesExpectedImage(
    Class runtimeClass) {
    return MTRuntimeClassMatchesImagePath(
        runtimeClass, MTUIKitCoreApplicationIconExpectedImagePath);
}

// Coexistence: any resolvable implementation — Apple's original, another
// Apple image, or another tweak's chained Hook — stays hookable so other
// tweaks keep working; the exact-image match is provenance only.
BOOL MTUIKitCoreApplicationIconImplementationMatchesExpectedImage(
    IMP implementation) {
    return MTRuntimeImplementationMatchesImage(
               implementation, MTUIKitCoreApplicationIconExpectedImagePath) ||
        MTRuntimeImplementationResolves(implementation);
}

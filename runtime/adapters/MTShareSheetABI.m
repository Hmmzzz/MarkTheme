#import "MTShareSheetABI.h"

#import "MTRuntimeImageABI.h"

static const char *const MTShareSheetExpectedImagePath =
    "/System/Library/PrivateFrameworks/ShareSheet.framework/ShareSheet";

BOOL MTShareSheetClassMatchesExpectedImage(Class runtimeClass) {
    return MTRuntimeClassMatchesImagePath(
        runtimeClass, MTShareSheetExpectedImagePath);
}

// Coexistence: any resolvable implementation — Apple's original, another
// Apple image, or another tweak's chained Hook — stays hookable so other
// tweaks keep working; the exact-image match is provenance only.
BOOL MTShareSheetImplementationMatchesExpectedImage(IMP implementation) {
    return MTRuntimeImplementationMatchesImage(
               implementation, MTShareSheetExpectedImagePath) ||
        MTRuntimeImplementationResolves(implementation);
}

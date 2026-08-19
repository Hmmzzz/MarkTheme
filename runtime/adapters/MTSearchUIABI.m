#import "MTSearchUIABI.h"

#import "MTRuntimeImageABI.h"

static const char *const MTSearchUIExpectedImagePath =
    "/System/Library/PrivateFrameworks/SearchUI.framework/SearchUI";

BOOL MTSearchUIClassMatchesExpectedImage(Class runtimeClass) {
    return MTRuntimeClassMatchesImagePath(
        runtimeClass, MTSearchUIExpectedImagePath);
}

// Coexistence: any resolvable implementation — Apple's original, another
// Apple image, or another tweak's chained Hook — stays hookable so other
// tweaks keep working; the exact-image match is provenance only.
BOOL MTSearchUIImplementationMatchesExpectedImage(IMP implementation) {
    return MTRuntimeImplementationMatchesImage(
               implementation, MTSearchUIExpectedImagePath) ||
        MTRuntimeImplementationResolves(implementation);
}

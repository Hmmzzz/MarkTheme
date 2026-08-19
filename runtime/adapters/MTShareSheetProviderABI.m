#import "MTShareSheetProviderABI.h"

#import "MTRuntimeImageABI.h"

static const char *const MTShareSheetProviderExpectedImagePath =
    "/System/Library/PrivateFrameworks/SharingUI.framework/SharingUI";

BOOL MTShareSheetProviderClassMatchesExpectedImage(Class runtimeClass) {
    return MTRuntimeClassMatchesImagePath(
        runtimeClass, MTShareSheetProviderExpectedImagePath);
}

// Coexistence: any resolvable implementation — Apple's original, another
// Apple image, or another tweak's chained Hook — stays hookable so other
// tweaks keep working; the exact-image match is provenance only.
BOOL MTShareSheetProviderImplementationMatchesExpectedImage(
    IMP implementation) {
    return MTRuntimeImplementationMatchesImage(
               implementation, MTShareSheetProviderExpectedImagePath) ||
        MTRuntimeImplementationResolves(implementation);
}

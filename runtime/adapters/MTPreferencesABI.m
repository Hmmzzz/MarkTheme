#import "MTPreferencesABI.h"

#import "MTRuntimeImageABI.h"

static const char *const MTPreferencesExpectedImagePath =
    "/System/Library/PrivateFrameworks/Preferences.framework/Preferences";

BOOL MTPreferencesClassMatchesExpectedImage(Class runtimeClass) {
    return MTRuntimeClassMatchesImagePath(
        runtimeClass, MTPreferencesExpectedImagePath);
}

// Coexistence: any resolvable implementation — Apple's original, another
// Apple image, or another tweak's chained Hook — stays hookable so other
// tweaks keep working; the exact-image match is provenance only.
BOOL MTPreferencesImplementationMatchesExpectedImage(IMP implementation) {
    return MTRuntimeImplementationMatchesImage(
               implementation, MTPreferencesExpectedImagePath) ||
        MTRuntimeImplementationResolves(implementation);
}

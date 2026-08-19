#import "MTPreferencesABI.h"

#import "MTRuntimeImageABI.h"

static const char *const MTPreferencesExpectedImagePath =
    "/System/Library/PrivateFrameworks/Preferences.framework/Preferences";

BOOL MTPreferencesClassMatchesExpectedImage(Class runtimeClass) {
    return MTRuntimeClassMatchesImagePath(
        runtimeClass, MTPreferencesExpectedImagePath);
}

BOOL MTPreferencesImplementationMatchesExpectedImage(IMP implementation) {
    return MTRuntimeImplementationMatchesImage(
        implementation, MTPreferencesExpectedImagePath);
}

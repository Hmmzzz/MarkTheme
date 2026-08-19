#import "MTShareSheetABI.h"

#import "MTRuntimeImageABI.h"

static const char *const MTShareSheetExpectedImagePath =
    "/System/Library/PrivateFrameworks/ShareSheet.framework/ShareSheet";

BOOL MTShareSheetClassMatchesExpectedImage(Class runtimeClass) {
    return MTRuntimeClassMatchesImagePath(
        runtimeClass, MTShareSheetExpectedImagePath);
}

BOOL MTShareSheetImplementationMatchesExpectedImage(IMP implementation) {
    return MTRuntimeImplementationMatchesImage(
        implementation, MTShareSheetExpectedImagePath);
}

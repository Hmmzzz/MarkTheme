#import "MTShareSheetProviderABI.h"

#import "MTRuntimeImageABI.h"

static const char *const MTShareSheetProviderExpectedImagePath =
    "/System/Library/PrivateFrameworks/SharingUI.framework/SharingUI";

BOOL MTShareSheetProviderClassMatchesExpectedImage(Class runtimeClass) {
    return MTRuntimeClassMatchesImagePath(
        runtimeClass, MTShareSheetProviderExpectedImagePath);
}

BOOL MTShareSheetProviderImplementationMatchesExpectedImage(
    IMP implementation) {
    return MTRuntimeImplementationMatchesImage(
        implementation, MTShareSheetProviderExpectedImagePath);
}

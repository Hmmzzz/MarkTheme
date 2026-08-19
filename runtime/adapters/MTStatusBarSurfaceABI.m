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

BOOL MTSystemStatusUIStatusBarImplementationMatchesExpectedImage(
    IMP implementation) {
    return MTRuntimeImplementationMatchesImage(
        implementation, MTSystemStatusUIStatusBarExpectedImagePath);
}

BOOL MTUIKitCoreStatusBarWindowImplementationMatchesExpectedImage(
    IMP implementation) {
    return MTRuntimeImplementationMatchesImage(
        implementation, MTUIKitCoreStatusBarWindowExpectedImagePath);
}

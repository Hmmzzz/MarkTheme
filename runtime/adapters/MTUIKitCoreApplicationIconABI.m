#import "MTUIKitCoreApplicationIconABI.h"

#import "MTRuntimeImageABI.h"

static const char *const MTUIKitCoreApplicationIconExpectedImagePath =
    "/System/Library/PrivateFrameworks/UIKitCore.framework/UIKitCore";

BOOL MTUIKitCoreApplicationIconClassMatchesExpectedImage(
    Class runtimeClass) {
    return MTRuntimeClassMatchesImagePath(
        runtimeClass, MTUIKitCoreApplicationIconExpectedImagePath);
}

BOOL MTUIKitCoreApplicationIconImplementationMatchesExpectedImage(
    IMP implementation) {
    return MTRuntimeImplementationMatchesImage(
        implementation, MTUIKitCoreApplicationIconExpectedImagePath);
}

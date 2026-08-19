#import "MTSearchUIABI.h"

#import "MTRuntimeImageABI.h"

static const char *const MTSearchUIExpectedImagePath =
    "/System/Library/PrivateFrameworks/SearchUI.framework/SearchUI";

BOOL MTSearchUIClassMatchesExpectedImage(Class runtimeClass) {
    return MTRuntimeClassMatchesImagePath(
        runtimeClass, MTSearchUIExpectedImagePath);
}

BOOL MTSearchUIImplementationMatchesExpectedImage(IMP implementation) {
    return MTRuntimeImplementationMatchesImage(
        implementation, MTSearchUIExpectedImagePath);
}

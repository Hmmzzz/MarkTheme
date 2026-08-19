#import "MTSpringBoardHomeABI.h"

#import "MTRuntimeImageABI.h"

static const char *const MTExpectedImagePath =
    "/System/Library/PrivateFrameworks/"
    "SpringBoardHome.framework/SpringBoardHome";
BOOL MTSpringBoardHomeImplementationMatchesExpectedImage(IMP implementation) {
    return MTRuntimeImplementationMatchesImage(
        implementation, MTExpectedImagePath);
}

BOOL MTSpringBoardHomeClassMatchesExpectedImage(Class runtimeClass) {
    return MTRuntimeClassMatchesImagePath(
        runtimeClass, MTExpectedImagePath);
}

BOOL MTRuntimeClassIsSubclassOfClass(Class runtimeClass,
                                     Class expectedClass) {
    for (Class candidate = runtimeClass;
         candidate != Nil; candidate = class_getSuperclass(candidate)) {
        if (candidate == expectedClass) return YES;
    }
    return NO;
}

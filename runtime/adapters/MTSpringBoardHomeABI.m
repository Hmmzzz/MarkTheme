#import "MTSpringBoardHomeABI.h"

#import "MTRuntimeImageABI.h"

static const char *const MTExpectedImagePath =
    "/System/Library/PrivateFrameworks/"
    "SpringBoardHome.framework/SpringBoardHome";
// Coexistence: any resolvable implementation — Apple's original, another
// Apple image after an OS layout change, or another tweak's chained Hook —
// stays hookable, so installing MarkTheme64e never disables another tweak.
// Hooking chains through whatever implementation is current; provenance is
// still reported per contract for diagnostics.
BOOL MTSpringBoardHomeImplementationMatchesExpectedImage(IMP implementation) {
    return MTRuntimeImplementationMatchesImage(
               implementation, MTExpectedImagePath) ||
        MTRuntimeImplementationResolves(implementation);
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

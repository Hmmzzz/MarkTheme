#import "MTSpringBoardHomeABI.h"

#import "MTRuntimeImageABI.h"

static const char *const MTExpectedImagePath =
    "/System/Library/PrivateFrameworks/"
    "SpringBoardHome.framework/SpringBoardHome";
// iOS minor releases legitimately move SpringBoard hook points between
// SpringBoardHome and other sealed system images (e.g. the SpringBoard
// executable), so implementation provenance accepts any Apple system image.
// A third-party Hook always resolves into a jailbreak bootstrap image
// outside the sealed system volume, which
// MTRuntimeImplementationMatchesSystemImagePath still rejects, keeping
// the never-chain-through-unknown-code guarantee across Apple's own layout
// drift instead of pinning one build's file layout.
BOOL MTSpringBoardHomeImplementationMatchesExpectedImage(IMP implementation) {
    return MTRuntimeImplementationMatchesImage(
               implementation, MTExpectedImagePath) ||
        MTRuntimeImplementationMatchesSystemImagePath(implementation);
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

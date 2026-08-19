#import "MTSpringBoardHomeABI.h"

#import "MTRuntimeImageABI.h"

NSString *const MTSpringBoardHomeExpectedImageUUID =
    @"AB2D43B6-42D4-3D34-B98A-83C6D3FA06A3";
static const char *const MTExpectedImagePath =
    "/System/Library/PrivateFrameworks/"
    "SpringBoardHome.framework/SpringBoardHome";
static const uint8_t MTExpectedImageUUID[16] = {
    0xab, 0x2d, 0x43, 0xb6, 0x42, 0xd4, 0x3d, 0x34,
    0xb9, 0x8a, 0x83, 0xc6, 0xd3, 0xfa, 0x06, 0xa3,
};
BOOL MTSpringBoardHomeImplementationMatchesExpectedImage(IMP implementation) {
    return MTRuntimeImplementationMatchesImage(
        implementation, MTExpectedImagePath, MTExpectedImageUUID);
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

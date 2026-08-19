#import "MTUIKitCoreApplicationIconABI.h"

#import "MTRuntimeImageABI.h"

NSString *const MTUIKitCoreApplicationIconExpectedImageUUID =
    @"2D538446-6E40-3C10-8A5F-559C938077A0";

static const char *const MTUIKitCoreApplicationIconExpectedImagePath =
    "/System/Library/PrivateFrameworks/UIKitCore.framework/UIKitCore";
static const uint8_t MTUIKitCoreApplicationIconExpectedImageUUIDBytes[16] = {
    0x2d, 0x53, 0x84, 0x46, 0x6e, 0x40, 0x3c, 0x10,
    0x8a, 0x5f, 0x55, 0x9c, 0x93, 0x80, 0x77, 0xa0,
};

BOOL MTUIKitCoreApplicationIconClassMatchesExpectedImage(
    Class runtimeClass) {
    return MTRuntimeClassMatchesImagePath(
        runtimeClass, MTUIKitCoreApplicationIconExpectedImagePath);
}

BOOL MTUIKitCoreApplicationIconImplementationMatchesExpectedImage(
    IMP implementation) {
    return MTRuntimeImplementationMatchesImage(
        implementation,
        MTUIKitCoreApplicationIconExpectedImagePath,
        MTUIKitCoreApplicationIconExpectedImageUUIDBytes);
}

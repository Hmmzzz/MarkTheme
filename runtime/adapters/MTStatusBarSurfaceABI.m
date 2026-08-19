#import "MTStatusBarSurfaceABI.h"

#import "MTRuntimeImageABI.h"

NSString *const MTSystemStatusUIStatusBarExpectedImageUUID =
    @"4CCAEDC1-945F-3BEC-831A-D5A54C26C0FA";
NSString *const MTUIKitCoreStatusBarWindowExpectedImageUUID =
    @"2D538446-6E40-3C10-8A5F-559C938077A0";

static const char *const MTSystemStatusUIStatusBarExpectedImagePath =
    "/System/Library/PrivateFrameworks/SystemStatusUI.framework/"
    "SystemStatusUI";
static const uint8_t
    MTSystemStatusUIStatusBarExpectedImageUUIDBytes[16] = {
        0x4c, 0xca, 0xed, 0xc1, 0x94, 0x5f, 0x3b, 0xec,
        0x83, 0x1a, 0xd5, 0xa5, 0x4c, 0x26, 0xc0, 0xfa,
    };
static const char *const MTUIKitCoreStatusBarWindowExpectedImagePath =
    "/System/Library/PrivateFrameworks/UIKitCore.framework/UIKitCore";
static const uint8_t
    MTUIKitCoreStatusBarWindowExpectedImageUUIDBytes[16] = {
        0x2d, 0x53, 0x84, 0x46, 0x6e, 0x40, 0x3c, 0x10,
        0x8a, 0x5f, 0x55, 0x9c, 0x93, 0x80, 0x77, 0xa0,
    };

BOOL MTSystemStatusUIStatusBarClassMatchesExpectedImage(
    Class runtimeClass) {
    return MTRuntimeClassMatchesImagePath(
        runtimeClass, MTSystemStatusUIStatusBarExpectedImagePath);
}

BOOL MTSystemStatusUIStatusBarImplementationMatchesExpectedImage(
    IMP implementation) {
    return MTRuntimeImplementationMatchesImage(
        implementation, MTSystemStatusUIStatusBarExpectedImagePath,
        MTSystemStatusUIStatusBarExpectedImageUUIDBytes);
}

BOOL MTUIKitCoreStatusBarWindowImplementationMatchesExpectedImage(
    IMP implementation) {
    return MTRuntimeImplementationMatchesImage(
        implementation, MTUIKitCoreStatusBarWindowExpectedImagePath,
        MTUIKitCoreStatusBarWindowExpectedImageUUIDBytes);
}

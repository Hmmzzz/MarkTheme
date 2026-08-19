#import "MTSearchUIABI.h"

#import "MTRuntimeImageABI.h"

NSString *const MTSearchUIExpectedImageUUID =
    @"7B9C7163-B90F-3370-9AE2-A928D1E6AD4A";

static const char *const MTSearchUIExpectedImagePath =
    "/System/Library/PrivateFrameworks/SearchUI.framework/SearchUI";
static const uint8_t MTSearchUIExpectedImageUUIDBytes[16] = {
    0x7b, 0x9c, 0x71, 0x63, 0xb9, 0x0f, 0x33, 0x70,
    0x9a, 0xe2, 0xa9, 0x28, 0xd1, 0xe6, 0xad, 0x4a,
};

BOOL MTSearchUIClassMatchesExpectedImage(Class runtimeClass) {
    return MTRuntimeClassMatchesImagePath(
        runtimeClass, MTSearchUIExpectedImagePath);
}

BOOL MTSearchUIImplementationMatchesExpectedImage(IMP implementation) {
    return MTRuntimeImplementationMatchesImage(
        implementation,
        MTSearchUIExpectedImagePath,
        MTSearchUIExpectedImageUUIDBytes);
}

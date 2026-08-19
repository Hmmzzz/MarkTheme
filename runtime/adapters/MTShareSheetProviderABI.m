#import "MTShareSheetProviderABI.h"

#import "MTRuntimeImageABI.h"

NSString *const MTShareSheetProviderExpectedImageUUID =
    @"DEC7881B-89EF-3E58-BDEE-D2659CD78479";

static const char *const MTShareSheetProviderExpectedImagePath =
    "/System/Library/PrivateFrameworks/SharingUI.framework/SharingUI";
static const uint8_t MTShareSheetProviderExpectedImageUUIDBytes[16] = {
    0xde, 0xc7, 0x88, 0x1b, 0x89, 0xef, 0x3e, 0x58,
    0xbd, 0xee, 0xd2, 0x65, 0x9c, 0xd7, 0x84, 0x79,
};

BOOL MTShareSheetProviderClassMatchesExpectedImage(Class runtimeClass) {
    return MTRuntimeClassMatchesImagePath(
        runtimeClass, MTShareSheetProviderExpectedImagePath);
}

BOOL MTShareSheetProviderImplementationMatchesExpectedImage(
    IMP implementation) {
    return MTRuntimeImplementationMatchesImage(
        implementation,
        MTShareSheetProviderExpectedImagePath,
        MTShareSheetProviderExpectedImageUUIDBytes);
}

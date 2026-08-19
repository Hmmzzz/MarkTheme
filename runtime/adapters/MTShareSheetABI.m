#import "MTShareSheetABI.h"

#import "MTRuntimeImageABI.h"

NSString *const MTShareSheetExpectedImageUUID =
    @"6F65949B-D485-38EB-93E6-00C6DEF41DA6";

static const char *const MTShareSheetExpectedImagePath =
    "/System/Library/PrivateFrameworks/ShareSheet.framework/ShareSheet";
static const uint8_t MTShareSheetExpectedImageUUIDBytes[16] = {
    0x6f, 0x65, 0x94, 0x9b, 0xd4, 0x85, 0x38, 0xeb,
    0x93, 0xe6, 0x00, 0xc6, 0xde, 0xf4, 0x1d, 0xa6,
};

BOOL MTShareSheetClassMatchesExpectedImage(Class runtimeClass) {
    return MTRuntimeClassMatchesImagePath(
        runtimeClass, MTShareSheetExpectedImagePath);
}

BOOL MTShareSheetImplementationMatchesExpectedImage(IMP implementation) {
    return MTRuntimeImplementationMatchesImage(
        implementation,
        MTShareSheetExpectedImagePath,
        MTShareSheetExpectedImageUUIDBytes);
}

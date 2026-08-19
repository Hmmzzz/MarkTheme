#import "MTPreferencesABI.h"

#import "MTRuntimeImageABI.h"

NSString *const MTPreferencesExpectedImageUUID =
    @"FB122D5B-9F56-3533-A225-E4409E311718";

static const char *const MTPreferencesExpectedImagePath =
    "/System/Library/PrivateFrameworks/Preferences.framework/Preferences";
static const uint8_t MTPreferencesExpectedImageUUIDBytes[16] = {
    0xfb, 0x12, 0x2d, 0x5b, 0x9f, 0x56, 0x35, 0x33,
    0xa2, 0x25, 0xe4, 0x40, 0x9e, 0x31, 0x17, 0x18,
};

BOOL MTPreferencesClassMatchesExpectedImage(Class runtimeClass) {
    return MTRuntimeClassMatchesImagePath(
        runtimeClass, MTPreferencesExpectedImagePath);
}

BOOL MTPreferencesImplementationMatchesExpectedImage(IMP implementation) {
    return MTRuntimeImplementationMatchesImage(
        implementation,
        MTPreferencesExpectedImagePath,
        MTPreferencesExpectedImageUUIDBytes);
}

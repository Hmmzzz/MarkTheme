#import "MTMobilePhoneDialerABI.h"

#import "MTRuntimeImageABI.h"

NSString *const MTMobilePhoneDialerExpectedImageUUID =
    @"29AC9902-D165-319B-89E3-D5B07F7EA766";
NSString *const MTTelephonyUIDialerExpectedImageUUID =
    @"E4CF3237-F30A-33B7-866E-9E06351E4D5A";

static const char *const MTMobilePhoneDialerExpectedImagePath =
    "/Applications/MobilePhone.app/MobilePhone";
static const uint8_t MTMobilePhoneDialerExpectedImageUUIDBytes[16] = {
    0x29, 0xac, 0x99, 0x02, 0xd1, 0x65, 0x31, 0x9b,
    0x89, 0xe3, 0xd5, 0xb0, 0x7f, 0x7e, 0xa7, 0x66,
};
static const char *const MTTelephonyUIDialerExpectedImagePath =
    "/System/Library/PrivateFrameworks/TelephonyUI.framework/TelephonyUI";
static const uint8_t MTTelephonyUIDialerExpectedImageUUIDBytes[16] = {
    0xe4, 0xcf, 0x32, 0x37, 0xf3, 0x0a, 0x33, 0xb7,
    0x86, 0x6e, 0x9e, 0x06, 0x35, 0x1e, 0x4d, 0x5a,
};

BOOL MTMobilePhoneDialerClassMatchesExpectedImage(Class runtimeClass) {
    return MTRuntimeClassMatchesImagePath(
        runtimeClass, MTMobilePhoneDialerExpectedImagePath);
}

BOOL MTMobilePhoneDialerImplementationMatchesExpectedImage(
    IMP implementation) {
    return MTRuntimeImplementationMatchesImage(
        implementation, MTMobilePhoneDialerExpectedImagePath,
        MTMobilePhoneDialerExpectedImageUUIDBytes);
}

BOOL MTTelephonyUIDialerClassMatchesExpectedImage(Class runtimeClass) {
    return MTRuntimeClassMatchesImagePath(
        runtimeClass, MTTelephonyUIDialerExpectedImagePath);
}

BOOL MTTelephonyUIDialerImplementationMatchesExpectedImage(
    IMP implementation) {
    return MTRuntimeImplementationMatchesImage(
        implementation, MTTelephonyUIDialerExpectedImagePath,
        MTTelephonyUIDialerExpectedImageUUIDBytes);
}

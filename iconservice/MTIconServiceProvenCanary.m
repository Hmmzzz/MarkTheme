#import "MTIconServiceProvenCanary.h"

#if !defined(MARKTHEME_ICON_SERVICE_PROVEN_CANARY)
#define MARKTHEME_ICON_SERVICE_PROVEN_CANARY 0
#endif

_Static_assert(MARKTHEME_ICON_SERVICE_PROVEN_CANARY == 0 ||
               MARKTHEME_ICON_SERVICE_PROVEN_CANARY == 1,
    "MARKTHEME_ICON_SERVICE_PROVEN_CANARY must be disabled or enabled");

static NSString *const MTIconServiceProvenCanaryBundleIdentifier =
    @"com.apple.Preferences";
static NSString *const MTIconServiceProvenCanaryIconDigest =
    @"B68AA0B6-EFEA-3DCD-AF68-A034411947FD";
static NSString *const MTIconServiceProvenCanaryDescriptorDigest =
    @"0A08A069-61D7-3C2F-8274-AC0C2BA0651D";

BOOL MTIconServiceProvenCanaryIsEnabled(void) {
    return MARKTHEME_ICON_SERVICE_PROVEN_CANARY == 1;
}

BOOL MTIconServiceProvenCanaryMatchesRequest(
    NSString *bundleIdentifier,
    NSUUID *iconDigest,
    NSUUID *descriptorDigest,
    CGSize pointSize,
    double scale) {
    return [bundleIdentifier
            isEqualToString:MTIconServiceProvenCanaryBundleIdentifier] &&
        [iconDigest.UUIDString.uppercaseString
            isEqualToString:MTIconServiceProvenCanaryIconDigest] &&
        [descriptorDigest.UUIDString.uppercaseString
            isEqualToString:MTIconServiceProvenCanaryDescriptorDigest] &&
        CGSizeEqualToSize(pointSize, CGSizeMake(61.25, 61.25)) &&
        scale == 2;
}

BOOL MTIconServiceProvenCanaryAllowsRequest(
    NSString *bundleIdentifier,
    NSUUID *iconDigest,
    NSUUID *descriptorDigest,
    CGSize pointSize,
    double scale) {
    return MTIconServiceProvenCanaryIsEnabled() &&
        MTIconServiceProvenCanaryMatchesRequest(
            bundleIdentifier, iconDigest, descriptorDigest, pointSize, scale);
}

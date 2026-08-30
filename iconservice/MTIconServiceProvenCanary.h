#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

// This compile-time gate exists only for the single request identity proven on
// the original reference device. It is disabled by default in source mode.
FOUNDATION_EXPORT BOOL MTIconServiceProvenCanaryIsEnabled(void);
FOUNDATION_EXPORT NSString *MTIconServiceProvenCanaryBundleIdentifier(void);
FOUNDATION_EXPORT NSUUID *MTIconServiceProvenCanaryIconDigest(void);
FOUNDATION_EXPORT NSUUID *MTIconServiceProvenCanaryDescriptorDigest(void);

FOUNDATION_EXPORT BOOL MTIconServiceProvenCanaryMatchesRequest(
    NSString *bundleIdentifier,
    NSUUID *iconDigest,
    NSUUID *descriptorDigest,
    CGSize pointSize,
    double scale);

FOUNDATION_EXPORT BOOL MTIconServiceProvenCanaryAllowsRequest(
    NSString *bundleIdentifier,
    NSUUID *iconDigest,
    NSUUID *descriptorDigest,
    CGSize pointSize,
    double scale);

NS_ASSUME_NONNULL_END

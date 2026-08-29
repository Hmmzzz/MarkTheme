#import "MTIconServiceRuntimeTests.h"

#import "MTIconServiceABI.h"
#import "MTIconServiceProvenCanary.h"
#import "MTIconServiceRuntimeMode.h"

static NSUInteger MTIconServiceAssertionCount;

static void MTIconServiceAssert(BOOL condition, NSString *message) {
    MTIconServiceAssertionCount++;
    if (condition) return;
    fprintf(stderr, "FAIL: %s\n", message.UTF8String);
    exit(1);
}

NSUInteger MTRunIconServiceRuntimeTests(void) {
    MTIconServiceAssertionCount = 0;
    MTIconServiceAssert(
        MTIconServiceConfiguredRuntimeMode() ==
            MTIconServiceRuntimeModeDisabled &&
        [MTIconServiceRuntimeModeName(MTIconServiceRuntimeModeDisabled)
            isEqualToString:@"disabled"] &&
        [MTIconServiceRuntimeModeName(MTIconServiceRuntimeModeObserve)
            isEqualToString:@"service-observe"] &&
        [MTIconServiceRuntimeModeName(MTIconServiceRuntimeModeSource)
            isEqualToString:@"service-source"],
        @"Host tests must use the fail-closed IconServices default while preserving stable rollout names");

    MTIconServiceImageGeometry proven = {
        .pixelSize = CGSizeMake(128, 128),
        .minimumSize = CGSizeMake(61, 61),
        .iconSize = CGSizeMake(64, 64),
        .scale = 2,
        .placeholder = NO,
        .largest = NO,
    };
    MTIconServiceAssert(MTIconServiceImageGeometryIsSupported(proven),
        @"The exact 21D61 IFCacheImage proof geometry must be accepted");
    MTIconServiceImageGeometry nonSquare = proven;
    nonSquare.pixelSize.height = 127;
    MTIconServiceImageGeometry placeholder = proven;
    placeholder.placeholder = YES;
    MTIconServiceImageGeometry mismatchedScale = proven;
    mismatchedScale.iconSize = CGSizeMake(63, 63);
    MTIconServiceAssert(
        !MTIconServiceImageGeometryIsSupported(nonSquare) &&
        !MTIconServiceImageGeometryIsSupported(placeholder) &&
        !MTIconServiceImageGeometryIsSupported(mismatchedScale),
        @"Unsupported IFImage geometry must fail closed before private construction");

    NSUUID *proofIconDigest = [[NSUUID alloc]
        initWithUUIDString:@"B68AA0B6-EFEA-3DCD-AF68-A034411947FD"];
    NSUUID *proofDescriptorDigest = [[NSUUID alloc]
        initWithUUIDString:@"0A08A069-61D7-3C2F-8274-AC0C2BA0651D"];
    MTIconServiceAssert(
        !MTIconServiceProvenCanaryIsEnabled() &&
        MTIconServiceProvenCanaryMatchesRequest(
            @"com.apple.Preferences", proofIconDigest,
            proofDescriptorDigest, CGSizeMake(61.25, 61.25), 2) &&
        !MTIconServiceProvenCanaryAllowsRequest(
            @"com.apple.Preferences", proofIconDigest,
            proofDescriptorDigest, CGSizeMake(61.25, 61.25), 2),
        @"The exact device-proof canary must match deterministically but remain disabled by default");
    MTIconServiceAssert(
        !MTIconServiceProvenCanaryMatchesRequest(
            @"com.apple.Preferences", proofIconDigest,
            proofDescriptorDigest, CGSizeMake(60, 60), 2) &&
        !MTIconServiceProvenCanaryMatchesRequest(
            @"com.apple.MobileSafari", proofIconDigest,
            proofDescriptorDigest, CGSizeMake(61.25, 61.25), 2),
        @"The device-proof canary must reject every unproven bundle or descriptor geometry");

    return MTIconServiceAssertionCount;
}

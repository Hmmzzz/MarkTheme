#import "MTIconServiceRuntimeTests.h"

#import "MTIconServiceABI.h"
#import "MTIconServiceRuntimeMode.h"
#import "MTIconServiceStoreIndex.h"

#include <string.h>

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
        @"The unshipped IconServices target must remain disabled by default with stable rollout names");

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

    uint8_t bytes[0x74] = {0};
    for (NSUInteger index = 0; index < 16; index++) {
        bytes[index] = (uint8_t)index;
        bytes[0x2c + index] = (uint8_t)(0x20 + index);
        bytes[0x3c + index] = (uint8_t)(0x40 + index);
    }
    double lower = 61;
    double upper = 64;
    double dimension = 64;
    uint32_t scale = 2;
    memcpy(bytes + 0x10, &lower, sizeof(lower));
    memcpy(bytes + 0x18, &upper, sizeof(upper));
    memcpy(bytes + 0x20, &dimension, sizeof(dimension));
    memcpy(bytes + 0x28, &scale, sizeof(scale));
    MTIconServiceStoreIndexValue value = {0};
    MTIconServiceAssert(
        MTIconServiceStoreIndexValueByteCount == sizeof(bytes) &&
        MTIconServiceStoreIndexReadValue(
            bytes, sizeof(bytes), &value) &&
        value.lowerSize == 61 && value.upperSize == 64 &&
        value.dimension == 64 && value.scaleDiscriminator == 2 &&
        MTIconServiceStoreIndexValueMatches(
            &value, bytes + 0x2c, bytes + 0x3c),
        @"The product StoreIndex contract must preserve the runtime-proven 0x74 layout and exact predicate fields");
    bytes[0x3c] ^= 0xff;
    MTIconServiceAssert(
        !MTIconServiceStoreIndexValueMatches(
            &value, bytes + 0x2c, bytes + 0x3c) &&
        !MTIconServiceStoreIndexReadValue(
            bytes, sizeof(bytes) - 1, &value),
        @"Targeted invalidation must reject a mismatched StoreUnit UUID and every non-0x74 record");
    return MTIconServiceAssertionCount;
}

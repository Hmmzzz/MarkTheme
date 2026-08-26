#import "MTRuntimeReplacementTests.h"

#import <CoreGraphics/CoreGraphics.h>

#import "MTRuntimeReplacement.h"
#import "modules/MTIconMaskCompositor.h"
#import "modules/MTStaticIconVisualProofContract.h"
#import "modules/MTSystemIconMaskProvider.h"

#include <math.h>

static NSUInteger MTRuntimeReplacementAssertionCount;
static NSUInteger MTResolverCallCount;
static NSString *MTResolverResourceIdentifier;
static id MTResolverOriginalResult;
static id MTResolverResult;

static CGImageRef MTTestCreateRGBAImage(size_t width,
                                        size_t height,
                                        const uint8_t *bytes) {
    CFDataRef data = CFDataCreate(
        kCFAllocatorDefault, bytes, (CFIndex)(width * height * 4));
    CGDataProviderRef provider = data == NULL ? NULL :
        CGDataProviderCreateWithCFData(data);
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGImageRef image = provider == NULL || colorSpace == NULL ? NULL :
        CGImageCreate(width, height, 8, 32, width * 4, colorSpace,
            kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big,
            provider, NULL, false, kCGRenderingIntentDefault);
    if (colorSpace != NULL) CGColorSpaceRelease(colorSpace);
    if (provider != NULL) CGDataProviderRelease(provider);
    if (data != NULL) CFRelease(data);
    return image;
}

static BOOL MTTestImageContainsAlphaValues(CGImageRef image,
                                           const uint8_t *expected,
                                           size_t expectedCount) {
    if (image == NULL ||
        CGImageGetWidth(image) * CGImageGetHeight(image) != expectedCount) {
        return NO;
    }
    CFDataRef data = CGDataProviderCopyData(CGImageGetDataProvider(image));
    if (data == NULL || CFDataGetLength(data) < (CFIndex)(expectedCount * 4)) {
        if (data != NULL) CFRelease(data);
        return NO;
    }
    const uint8_t *bytes = CFDataGetBytePtr(data);
    BOOL matched[4] = { NO, NO, NO, NO };
    BOOL valid = expectedCount <= 4;
    for (size_t pixel = 0; valid && pixel < expectedCount; pixel++) {
        uint8_t alpha = bytes[pixel * 4 + 3];
        BOOL found = NO;
        for (size_t index = 0; index < expectedCount; index++) {
            int delta = (int)alpha - (int)expected[index];
            if (!matched[index] && delta >= -1 && delta <= 1) {
                matched[index] = YES;
                found = YES;
                break;
            }
        }
        valid = found;
    }
    CFRelease(data);
    return valid;
}

static BOOL MTTestImageContainsRGBAValues(CGImageRef image,
                                          const uint8_t *expected,
                                          size_t expectedPixelCount) {
    if (image == NULL || expected == NULL || expectedPixelCount > 8 ||
        CGImageGetWidth(image) * CGImageGetHeight(image) !=
            expectedPixelCount) {
        return NO;
    }
    CFDataRef data = CGDataProviderCopyData(CGImageGetDataProvider(image));
    if (data == NULL ||
        CFDataGetLength(data) < (CFIndex)(expectedPixelCount * 4)) {
        if (data != NULL) CFRelease(data);
        return NO;
    }
    const uint8_t *bytes = CFDataGetBytePtr(data);
    BOOL matched[8] = { NO, NO, NO, NO, NO, NO, NO, NO };
    BOOL valid = YES;
    for (size_t pixel = 0; valid && pixel < expectedPixelCount; pixel++) {
        BOOL found = NO;
        for (size_t index = 0; index < expectedPixelCount; index++) {
            if (matched[index]) continue;
            BOOL componentMatch = YES;
            for (size_t component = 0; component < 4; component++) {
                int delta = (int)bytes[pixel * 4 + component] -
                    (int)expected[index * 4 + component];
                if (delta < -1 || delta > 1) {
                    componentMatch = NO;
                    break;
                }
            }
            if (componentMatch) {
                matched[index] = YES;
                found = YES;
                break;
            }
        }
        valid = found;
    }
    CFRelease(data);
    return valid;
}

static void MTRuntimeReplacementAssert(BOOL condition, NSString *message) {
    MTRuntimeReplacementAssertionCount++;
    if (condition) return;
    fprintf(stderr, "FAIL: %s\n", message.UTF8String);
    exit(1);
}

static id MTTestReplacementResolver(NSString *resourceIdentifier,
                                    id originalResult) {
    MTResolverCallCount++;
    MTResolverResourceIdentifier = resourceIdentifier;
    MTResolverOriginalResult = originalResult;
    return MTResolverResult;
}

static void MTResetResolver(id result) {
    MTResolverCallCount = 0;
    MTResolverResourceIdentifier = nil;
    MTResolverOriginalResult = nil;
    MTResolverResult = result;
}

NSUInteger MTRunRuntimeReplacementTests(void) {
    MTRuntimeReplacementAssertionCount = 0;
    NSObject *original = [[NSObject alloc] init];
    NSObject *replacement = [[NSObject alloc] init];

    MTResetResolver(nil);
    BOOL didReplace = YES;
    id result = MTRuntimeResultByApplyingReplacementResolver(
        @"com.example.miss", original, MTTestReplacementResolver,
        &didReplace);
    MTRuntimeReplacementAssert(result == original && !didReplace,
        @"A resolver miss must return the exact original object");
    MTRuntimeReplacementAssert(MTResolverCallCount == 1 &&
        [MTResolverResourceIdentifier isEqualToString:@"com.example.miss"] &&
        MTResolverOriginalResult == original,
        @"The selected resolver must receive one stable key and original");

    MTResetResolver(replacement);
    didReplace = NO;
    result = MTRuntimeResultByApplyingReplacementResolver(
        MTStaticIconVisualProofTargetBundleIdentifier,
        original, MTTestReplacementResolver, &didReplace);
    MTRuntimeReplacementAssert(result == replacement && didReplace &&
        MTResolverCallCount == 1,
        @"A resolver hit must return its replacement exactly once");

    MTResetResolver(nil);
    didReplace = YES;
    result = MTRuntimeResultByApplyingReplacementResolver(
        @"com.example.nil", nil, MTTestReplacementResolver, &didReplace);
    MTRuntimeReplacementAssert(result == nil && !didReplace &&
        MTResolverOriginalResult == nil,
        @"A miss must preserve an original nil result");

    MTRuntimeReplacementAssert(
        MTStaticIconVisualProofMatchesTarget(@"com.hmmzzz.marktheme"),
        @"The visual proof must select the project-owned target App");
    MTRuntimeReplacementAssert(
        !MTStaticIconVisualProofMatchesTarget(@"com.hmmzzz.marktheme.other"),
        @"The visual proof lookup must use exact bundle identity");
    MTRuntimeReplacementAssert(
        CGSizeEqualToSize(MTStaticIconVisualProofExpectedPointSize,
                          CGSizeMake(60, 60)) &&
        MTStaticIconVisualProofExpectedScale == 3,
        @"The visual proof contract must stay pinned to the proven Probe3 dimensions");
    MTRuntimeReplacementAssert(
        MTStaticIconVisualProofImageContractIsSupported(
            MTStaticIconVisualProofExpectedPointSize,
            MTStaticIconVisualProofExpectedScale),
        @"The proven Probe3 image contract must be accepted");
    MTRuntimeReplacementAssert(
        !MTStaticIconVisualProofImageContractIsSupported(
            CGSizeMake(60, 61), 3) &&
        !MTStaticIconVisualProofImageContractIsSupported(
            CGSizeMake(60, 60), 2),
        @"A non-Probe3 image contract must remain stock fallback");
    MTRuntimeReplacementAssert(
        !MTStaticIconVisualProofImageContractIsSupported(
            CGSizeMake(NAN, 60), 3) &&
        !MTStaticIconVisualProofImageContractIsSupported(
            CGSizeMake(60, 60), INFINITY) &&
        !MTStaticIconVisualProofImageContractIsSupported(
            CGSizeMake(60, 60), 0),
        @"Non-finite or unsupported scale contracts must remain stock fallback");
    MTRuntimeReplacementAssert(
        CGSizeEqualToSize(MTStaticIconShareSheetMoreExpectedPointSize,
                          CGSizeMake(29, 29)) &&
        MTStaticIconShareSheetImageContractIsSupported(
            MTStaticIconVisualProofExpectedPointSize, 3) &&
        MTStaticIconShareSheetImageContractIsSupported(
            MTStaticIconShareSheetMoreExpectedPointSize, 3),
        @"Share Sheet must accept the proven 60pt top row and 29pt More list contracts");
    MTRuntimeReplacementAssert(
        MTStaticIconShareSheetImageContractIsSupported(
            CGSizeMake(28, 28), 3) &&
        MTStaticIconShareSheetImageContractIsSupported(
            CGSizeMake(29, 29), 2),
        @"Share Sheet contracts must follow the live square output geometry on both Retina scales");
    MTRuntimeReplacementAssert(
        MTStaticIconSystemSurfaceImageContractIsSupported(
            CGSizeMake(16, 16), 3) &&
        MTStaticIconSystemSurfaceImageContractIsSupported(
            CGSizeMake(29, 29), 3) &&
        MTStaticIconSystemSurfaceImageContractIsSupported(
            CGSizeMake(40, 40), 3) &&
        MTStaticIconSystemSurfaceImageContractIsSupported(
            CGSizeMake(60, 60), 3),
        @"The bounded system-surface contract must cover SearchUI, Share, App Switcher, and Home sizes");
    MTRuntimeReplacementAssert(
        MTStaticIconSystemSurfaceImageContractIsSupported(
            CGSizeMake(64, 64), 3) &&
        MTStaticIconSystemSurfaceImageContractIsSupported(
            CGSizeMake(40, 40), 2),
        @"Icon geometry from untested iPhone families and @2x displays must theme, not fall back to stock");
    MTRuntimeReplacementAssert(
        MTStaticIconSystemSurfaceImageContractIsSupported(
            CGSizeMake(11, 11), 3) &&
        MTStaticIconSystemSurfaceImageContractIsSupported(
            CGSizeMake(40, 40), 1) &&
        !MTStaticIconSystemSurfaceImageContractIsSupported(
            CGSizeMake(40, 39), 3) &&
        !MTStaticIconSystemSurfaceImageContractIsSupported(
            CGSizeMake(400, 400), 3) &&
        !MTStaticIconSystemSurfaceImageContractIsSupported(
            CGSizeMake(40, 40), 2.5) &&
        !MTStaticIconSystemSurfaceImageContractIsSupported(
            CGSizeMake(NAN, 40), 3),
        @"Tiny and scale-one icon carriers must theme while non-square, oversized, or non-integral contracts remain stock");

    NSObject *systemMask = [[NSObject alloc] init];
    NSObject *secondSystemMask = [[NSObject alloc] init];
    NSObject *renderLock = [[NSObject alloc] init];
    __block NSUInteger systemMaskRenderCount = 0;
    id provider = MTSystemIconMaskProviderCreateForTesting(
        ^id(CGSize pointSize, CGFloat scale) {
            @synchronized (renderLock) {
                systemMaskRenderCount++;
            }
            return CGSizeEqualToSize(pointSize, CGSizeMake(60, 60)) &&
                scale == 3 ? systemMask : secondSystemMask;
        });
    MTRuntimeReplacementAssert(
        MTSystemIconMaskProviderImageForTesting(
            provider, CGSizeMake(11, 10), 3) == nil &&
        systemMaskRenderCount == 0,
        @"The system-mask provider must reject unsupported contracts before invoking IconServices");
    __block BOOL concurrentSystemMaskMismatch = NO;
    dispatch_apply(32,
        dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0),
        ^(size_t index) {
            (void)index;
            if (MTSystemIconMaskProviderImageForTesting(
                    provider, CGSizeMake(60, 60), 3) != systemMask) {
                @synchronized (renderLock) {
                    concurrentSystemMaskMismatch = YES;
                }
            }
        });
    MTRuntimeReplacementAssert(
        !concurrentSystemMaskMismatch && systemMaskRenderCount == 1,
        @"Concurrent first system-mask requests must render one deterministic cached carrier");
    MTRuntimeReplacementAssert(
        MTSystemIconMaskProviderImageForTesting(
            provider, CGSizeMake(29, 29), 3) == secondSystemMask &&
        MTSystemIconMaskProviderImageForTesting(
            provider, CGSizeMake(29, 29), 3) == secondSystemMask &&
        systemMaskRenderCount == 2,
        @"Each supported system-mask size must render once and reuse its exact cached object");

    const uint8_t sourceBytes[16] = {
        255, 0, 0, 255, 255, 0, 0, 255,
        255, 0, 0, 255, 255, 0, 0, 255,
    };
    const uint8_t maskBytes[16] = {
        0, 0, 0, 0, 255, 0, 0, 64,
        0, 255, 0, 128, 255, 255, 255, 255,
    };
    CGImageRef sourceImage = MTTestCreateRGBAImage(2, 2, sourceBytes);
    CGImageRef maskImage = MTTestCreateRGBAImage(2, 2, maskBytes);
    CGImageRef composed = MTIconMaskCreateImage(sourceImage, maskImage);
    const uint8_t expectedAlpha[4] = { 0, 64, 128, 255 };
    const uint8_t expectedComposedBytes[16] = {
        0, 0, 0, 0, 64, 0, 0, 64,
        128, 0, 0, 128, 255, 0, 0, 255,
    };
    MTRuntimeReplacementAssert(
        MTTestImageContainsAlphaValues(composed, expectedAlpha, 4) &&
        MTTestImageContainsRGBAValues(
            composed, expectedComposedBytes, 4),
        @"Icon mask composition must preserve source color while multiplying only mask alpha");
    const uint8_t systemCarrierBytes[16] = {
        255, 255, 255, 0, 255, 255, 255, 0,
        255, 255, 255, 0, 255, 255, 255, 0,
    };
    CGImageRef systemCarrier = MTTestCreateRGBAImage(
        2, 2, systemCarrierBytes);
    MTRuntimeReplacementAssert(
        MTIconMaskHasTransparentCornerPixels(systemCarrier),
        @"A system-shape carrier must prove fully transparent alpha at all four corners");

    const uint8_t partialCarrierBytes[16] = {
        255, 255, 255, 0, 255, 255, 255, 255,
        255, 255, 255, 255, 255, 255, 255, 255,
    };
    CGImageRef partialCarrier = MTTestCreateRGBAImage(
        2, 2, partialCarrierBytes);
    MTRuntimeReplacementAssert(
        !MTIconMaskHasTransparentCornerPixels(partialCarrier),
        @"A partially transparent carrier must fail to stock instead of exposing remaining square corners");

    const uint8_t opaqueColorMaskBytes[16] = {
        0, 0, 0, 255, 255, 0, 0, 255,
        0, 255, 0, 255, 255, 255, 255, 255,
    };
    CGImageRef opaqueColorMask = MTTestCreateRGBAImage(
        2, 2, opaqueColorMaskBytes);
    CGImageRef colorIgnored = MTIconMaskCreateImage(
        sourceImage, opaqueColorMask);
    const uint8_t opaqueAlpha[4] = { 255, 255, 255, 255 };
    MTRuntimeReplacementAssert(
        MTTestImageContainsAlphaValues(colorIgnored, opaqueAlpha, 4) &&
        !MTIconMaskHasTransparentCornerPixels(opaqueColorMask),
        @"Mask RGB values must not become an undocumented icon overlay");

    // An overlay is additive artwork: opaque overlay pixels win, fully
    // transparent ones leave the icon exactly as it was.
    const uint8_t overlayBytes[16] = {
        0, 0, 0, 0, 0, 0, 255, 255,
        0, 0, 0, 0, 0, 0, 255, 255,
    };
    CGImageRef overlayImage = MTTestCreateRGBAImage(2, 2, overlayBytes);
    CGImageRef overlaid = MTIconOverlayCreateImage(
        sourceImage, overlayImage);
    const uint8_t expectedOverlaidBytes[16] = {
        255, 0, 0, 255, 0, 0, 255, 255,
        255, 0, 0, 255, 0, 0, 255, 255,
    };
    const uint8_t overlaidAlpha[4] = { 255, 255, 255, 255 };
    MTRuntimeReplacementAssert(
        MTTestImageContainsRGBAValues(
            overlaid, expectedOverlaidBytes, 4) &&
        MTTestImageContainsAlphaValues(overlaid, overlaidAlpha, 4),
        @"Icon overlay composition must draw over the source without clipping any source pixel");

    // The one supported order is mask first, then overlay. A transparent
    // overlay pixel must not resurrect an area the mask already cut away.
    CGImageRef maskedThenOverlaid = MTIconOverlayCreateImage(
        composed, overlayImage);
    const uint8_t expectedOrderedBytes[16] = {
        0, 0, 0, 0, 0, 0, 255, 255,
        128, 0, 0, 128, 0, 0, 255, 255,
    };
    MTRuntimeReplacementAssert(
        MTTestImageContainsRGBAValues(
            maskedThenOverlaid, expectedOrderedBytes, 4),
        @"Mask-then-overlay composition must keep the mask cut where the overlay is transparent");

    const uint8_t onePixelMaskBytes[4] = { 255, 255, 255, 255 };
    CGImageRef onePixelMask = MTTestCreateRGBAImage(
        1, 1, onePixelMaskBytes);
    MTRuntimeReplacementAssert(
        MTIconMaskCreateImage(sourceImage, onePixelMask) == NULL &&
        MTIconMaskCreateImage(NULL, maskImage) == NULL &&
        MTIconOverlayCreateImage(sourceImage, onePixelMask) == NULL &&
        MTIconOverlayCreateImage(sourceImage, NULL) == NULL,
        @"Invalid or dimension-mismatched mask requests must fail closed");
    if (maskedThenOverlaid != NULL) CGImageRelease(maskedThenOverlaid);
    if (overlaid != NULL) CGImageRelease(overlaid);
    if (overlayImage != NULL) CGImageRelease(overlayImage);
    if (onePixelMask != NULL) CGImageRelease(onePixelMask);
    if (partialCarrier != NULL) CGImageRelease(partialCarrier);
    if (systemCarrier != NULL) CGImageRelease(systemCarrier);
    if (colorIgnored != NULL) CGImageRelease(colorIgnored);
    if (opaqueColorMask != NULL) CGImageRelease(opaqueColorMask);
    if (composed != NULL) CGImageRelease(composed);
    if (maskImage != NULL) CGImageRelease(maskImage);
    if (sourceImage != NULL) CGImageRelease(sourceImage);
    return MTRuntimeReplacementAssertionCount;
}

#import "MTStaticIconVisualProofContract.h"

#include <math.h>

NSString *const MTStaticIconVisualProofTargetBundleIdentifier =
    @"com.hmmzzz.marktheme";
const CGSize MTStaticIconVisualProofExpectedPointSize = {60, 60};
const CGFloat MTStaticIconVisualProofExpectedScale = 3;

// Bounds on the decoded raster rather than on any one device's icon metrics.
// System producers, rather than theme artwork, own this requested geometry.
// A 1px floor keeps tiny glyph carriers themeable; 512px covers current icon
// families while remaining far below a full-screen image allocation.
const CGFloat MTStaticIconMinimumScale = 1;
const CGFloat MTStaticIconMaximumScale = 3;
const CGFloat MTStaticIconMinimumPixelDimension = 1;
const CGFloat MTStaticIconMaximumPixelDimension = 512;

BOOL MTStaticIconVisualProofMatchesTarget(NSString *bundleIdentifier) {
    return [bundleIdentifier
        isEqualToString:MTStaticIconVisualProofTargetBundleIdentifier];
}

BOOL MTStaticIconVisualProofImageContractIsSupported(CGSize pointSize,
                                                      CGFloat scale) {
    return CGSizeEqualToSize(
        pointSize, MTStaticIconVisualProofExpectedPointSize) &&
        scale == MTStaticIconVisualProofExpectedScale;
}

BOOL MTStaticIconSystemSurfaceImageContractIsSupported(CGSize pointSize,
                                                        CGFloat scale) {
    if (!isfinite(pointSize.width) || !isfinite(pointSize.height) ||
        !isfinite(scale) || pointSize.width != pointSize.height) {
        return NO;
    }
    // The screen scale is a device property, not a build-time constant, so the
    // contract accepts any integral Retina factor rather than one display's
    // value. Themed artwork is decoded to the requested pixel dimensions, so
    // the point size itself carries no upper bound here; only the resulting
    // pixel geometry has to be a sane, whole, square raster.
    if (scale < MTStaticIconMinimumScale ||
        scale > MTStaticIconMaximumScale || scale != floor(scale)) {
        return NO;
    }
    CGFloat pixelDimension = pointSize.width * scale;
    return isfinite(pixelDimension) &&
        pixelDimension >= MTStaticIconMinimumPixelDimension &&
        pixelDimension <= MTStaticIconMaximumPixelDimension &&
        pixelDimension == floor(pixelDimension);
}

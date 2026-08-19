#import "MTStaticIconVisualProofContract.h"

#include <math.h>

NSString *const MTStaticIconVisualProofTargetBundleIdentifier =
    @"com.hmmzzz.marktheme";
const CGSize MTStaticIconVisualProofExpectedPointSize = {60, 60};
const CGFloat MTStaticIconVisualProofExpectedScale = 3;
const CGSize MTStaticIconShareSheetMoreExpectedPointSize = {29, 29};

// Bounds on the decoded raster rather than on any one device's icon metrics.
// 36px preserves the previously proven 12pt@3x floor while staying meaningful
// on a @2x display; 256px clears every application-icon raster iOS requests
// (a 60pt Home Screen icon is 180px, and larger iPhone families stay well
// inside this) without admitting arbitrary full-screen artwork that reaches
// the same replacement path.
const CGFloat MTStaticIconMinimumScale = 2;
const CGFloat MTStaticIconMaximumScale = 3;
const CGFloat MTStaticIconMinimumPixelDimension = 36;
const CGFloat MTStaticIconMaximumPixelDimension = 256;

CGFloat MTStaticIconClampedPrewarmScale(CGFloat reportedScale) {
    CGFloat scale = isfinite(reportedScale) && reportedScale > 0
        ? floor(reportedScale) : MTStaticIconVisualProofExpectedScale;
    if (scale < MTStaticIconMinimumScale) return MTStaticIconMinimumScale;
    if (scale > MTStaticIconMaximumScale) return MTStaticIconMaximumScale;
    return scale;
}

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

BOOL MTStaticIconShareSheetImageContractIsSupported(CGSize pointSize,
                                                     CGFloat scale) {
    return MTStaticIconVisualProofImageContractIsSupported(pointSize, scale) ||
        (CGSizeEqualToSize(
             pointSize, MTStaticIconShareSheetMoreExpectedPointSize) &&
         scale == MTStaticIconVisualProofExpectedScale);
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

#import "MTStaticIconVisualProofContract.h"

#include <math.h>

NSString *const MTStaticIconVisualProofTargetBundleIdentifier =
    @"com.hmmzzz.marktheme";
const CGSize MTStaticIconVisualProofExpectedPointSize = {60, 60};
const CGFloat MTStaticIconVisualProofExpectedScale = 3;
const CGSize MTStaticIconShareSheetMoreExpectedPointSize = {29, 29};

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
        !isfinite(scale) || scale != MTStaticIconVisualProofExpectedScale ||
        pointSize.width != pointSize.height || pointSize.width < 12.0 ||
        pointSize.width > MTStaticIconVisualProofExpectedPointSize.width) {
        return NO;
    }
    CGFloat pixelDimension = pointSize.width * scale;
    return isfinite(pixelDimension) && pixelDimension >= 1.0 &&
        pixelDimension == floor(pixelDimension);
}

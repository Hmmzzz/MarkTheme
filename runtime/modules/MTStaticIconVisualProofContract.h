#import <Foundation/Foundation.h>

#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const
    MTStaticIconVisualProofTargetBundleIdentifier;
FOUNDATION_EXPORT const CGSize
    MTStaticIconVisualProofExpectedPointSize;
FOUNDATION_EXPORT const CGFloat
    MTStaticIconVisualProofExpectedScale;
FOUNDATION_EXPORT const CGFloat MTStaticIconMinimumScale;
FOUNDATION_EXPORT const CGFloat MTStaticIconMaximumScale;
FOUNDATION_EXPORT const CGFloat MTStaticIconMinimumPixelDimension;
FOUNDATION_EXPORT const CGFloat MTStaticIconMaximumPixelDimension;

FOUNDATION_EXPORT BOOL MTStaticIconVisualProofMatchesTarget(
    NSString *bundleIdentifier);
FOUNDATION_EXPORT BOOL MTStaticIconVisualProofImageContractIsSupported(
    CGSize pointSize,
    CGFloat scale);
// Accepts any square application-icon raster the running device asks for,
// bounded by pixel dimensions rather than by one display's point metrics.
// Home Screen icons differ in point size across iPhone families and the
// screen scale is a device property, so pinning either would leave untested
// hardware on stock artwork. The remaining Runtime consumer is the dedicated
// live Calendar/Clock path; ordinary application surfaces are sourced by
// IconServices.
FOUNDATION_EXPORT BOOL MTStaticIconSystemSurfaceImageContractIsSupported(
    CGSize pointSize,
    CGFloat scale);

NS_ASSUME_NONNULL_END

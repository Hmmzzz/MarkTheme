#import <Foundation/Foundation.h>

#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const
    MTStaticIconVisualProofTargetBundleIdentifier;
FOUNDATION_EXPORT const CGSize
    MTStaticIconVisualProofExpectedPointSize;
FOUNDATION_EXPORT const CGFloat
    MTStaticIconVisualProofExpectedScale;
FOUNDATION_EXPORT const CGSize
    MTStaticIconShareSheetMoreExpectedPointSize;
// Normalizes a display scale reported by the caller into the accepted range,
// so prewarming targets the geometry the running device will actually request
// instead of one build's pinned factor. A non-finite or absent value falls
// back to the historical @3x contract. Kept free of UIKit: the caller owns
// the screen query, this file owns only the bounds.
FOUNDATION_EXPORT CGFloat MTStaticIconClampedPrewarmScale(CGFloat reportedScale);

FOUNDATION_EXPORT const CGFloat MTStaticIconMinimumScale;
FOUNDATION_EXPORT const CGFloat MTStaticIconMaximumScale;
FOUNDATION_EXPORT const CGFloat MTStaticIconMinimumPixelDimension;
FOUNDATION_EXPORT const CGFloat MTStaticIconMaximumPixelDimension;

FOUNDATION_EXPORT BOOL MTStaticIconVisualProofMatchesTarget(
    NSString *bundleIdentifier);
FOUNDATION_EXPORT BOOL MTStaticIconVisualProofImageContractIsSupported(
    CGSize pointSize,
    CGFloat scale);
FOUNDATION_EXPORT BOOL MTStaticIconShareSheetImageContractIsSupported(
    CGSize pointSize,
    CGFloat scale);
// Accepts any square application-icon raster the running device asks for,
// bounded by pixel dimensions rather than by one display's point metrics.
// Home Screen icons differ in point size across iPhone families and the
// screen scale is a device property, so pinning either would leave untested
// hardware on stock artwork. App Switcher headers and SearchUI/Siri
// suggestion variants pass the same bounds, while unrelated full-screen UI
// images reaching this path are still refused.
FOUNDATION_EXPORT BOOL MTStaticIconSystemSurfaceImageContractIsSupported(
    CGSize pointSize,
    CGFloat scale);

NS_ASSUME_NONNULL_END

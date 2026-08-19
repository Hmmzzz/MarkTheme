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

FOUNDATION_EXPORT BOOL MTStaticIconVisualProofMatchesTarget(
    NSString *bundleIdentifier);
FOUNDATION_EXPORT BOOL MTStaticIconVisualProofImageContractIsSupported(
    CGSize pointSize,
    CGFloat scale);
FOUNDATION_EXPORT BOOL MTStaticIconShareSheetImageContractIsSupported(
    CGSize pointSize,
    CGFloat scale);
// Exact 21D61 iPhone system application-icon surfaces use square @3x
// contracts no larger than the 60pt Home Screen icon. This bounded contract
// also covers App Switcher headers and SearchUI/Siri suggestion variants
// without accepting arbitrary artwork dimensions from unrelated UI images.
FOUNDATION_EXPORT BOOL MTStaticIconSystemSurfaceImageContractIsSupported(
    CGSize pointSize,
    CGFloat scale);

NS_ASSUME_NONNULL_END

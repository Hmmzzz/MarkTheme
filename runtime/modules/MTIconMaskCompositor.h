#import <Foundation/Foundation.h>

#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

// Creates one same-size RGBA image whose pixels are the source multiplied by
// the mask's alpha channel. Mask RGB is deliberately ignored: the maintained
// IconBundles corpus proves alpha-mask semantics but not a pattern overlay.
FOUNDATION_EXPORT CGImageRef _Nullable MTIconMaskCreateImage(
    CGImageRef _Nullable sourceImage,
    CGImageRef _Nullable maskImage) CF_RETURNS_RETAINED;

// A stock image may act as the system-shape carrier only when at least one
// sampled corner is actually transparent. This prevents an opaque provider
// image from turning a theme source into the same raw rectangle.
FOUNDATION_EXPORT BOOL MTIconMaskHasTransparentCornerPixels(
    CGImageRef _Nullable maskImage);

NS_ASSUME_NONNULL_END

#import "MTIconCompositorTests.h"
#import "modules/MTIconMaskCompositor.h"

static NSUInteger MTCompositorAssertions;
static void MTCompositorCheck(BOOL condition, NSString *message) {
    MTCompositorAssertions++;
    if (condition) return;
    fprintf(stderr, "FAIL: %s\n", message.UTF8String);
    exit(1);
}

// Deterministic premultiplied RGBA samples include transparent, opaque and
// fractional-alpha pixels; RGB under the mask deliberately varies.
static CGImageRef MTCompositorFixture(size_t width, size_t height,
                                      uint32_t seed, BOOL opaque) {
    CGColorSpaceRef color = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(NULL, width, height, 8,
        width * 4, color,
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(color);
    if (context == NULL) return NULL;
    uint8_t *bytes = CGBitmapContextGetData(context);
    for (size_t i = 0; i < width * height; i++) {
        seed = seed * 1664525u + 1013904223u;
        uint8_t alpha = opaque ? 255 : (uint8_t)(seed >> 24);
        bytes[i * 4] = (uint8_t)(((seed >> 16) & 255u) * alpha / 255u);
        bytes[i * 4 + 1] = (uint8_t)(((seed >> 8) & 255u) * alpha / 255u);
        bytes[i * 4 + 2] = (uint8_t)((seed & 255u) * alpha / 255u);
        bytes[i * 4 + 3] = alpha;
    }
    CGImageRef result = CGBitmapContextCreateImage(context);
    CGContextRelease(context);
    return result;
}

static BOOL MTCompositorImagesEqual(CGImageRef left, CGImageRef right) {
    if (left == NULL || right == NULL) return left == right;
    if (CGImageGetWidth(left) != CGImageGetWidth(right) ||
        CGImageGetHeight(left) != CGImageGetHeight(right)) return NO;
    CFDataRef a = CGDataProviderCopyData(CGImageGetDataProvider(left));
    CFDataRef b = CGDataProviderCopyData(CGImageGetDataProvider(right));
    BOOL equal = a != NULL && b != NULL && CFEqual(a, b);
    if (a != NULL) CFRelease(a);
    if (b != NULL) CFRelease(b);
    return equal;
}

NSUInteger MTRunIconCompositorTests(void) {
    MTCompositorAssertions = 0;
    for (NSUInteger sizeIndex = 0; sizeIndex < 4; sizeIndex++) {
        size_t width = (size_t[]){1, 37, 120, 180}[sizeIndex];
        size_t height = sizeIndex == 1 ? 19 : width;
        CGImageRef source = MTCompositorFixture(width, height, 13, sizeIndex % 2 == 0);
        CGImageRef mask = MTCompositorFixture(width, height, 17, NO);
        CGImageRef overlay = MTCompositorFixture(width, height, 23, NO);
        MTCompositorCheck(source != NULL && mask != NULL && overlay != NULL,
            @"Compositor fixtures must allocate bounded premultiplied rasters");
        CGImageRef masked = MTIconMaskCreateImage(source, mask);
        CGImageRef reference = MTIconOverlayCreateImage(masked, overlay);
        CGImageRef fused = MTIconCompositeCreateImage(source, mask, overlay);
        MTCompositorCheck(MTCompositorImagesEqual(reference, fused),
            @"One-pass composition must preserve every pixel of the two-pass pipeline");
        CGImageRef maskOnly = MTIconCompositeCreateImage(source, mask, NULL);
        MTCompositorCheck(MTCompositorImagesEqual(masked, maskOnly),
            @"Mask-only composition preserves alpha multiplication");
        CGImageRef overlayOnly = MTIconCompositeCreateImage(source, NULL, overlay);
        CGImageRef oldOverlay = MTIconOverlayCreateImage(source, overlay);
        MTCompositorCheck(MTCompositorImagesEqual(oldOverlay, overlayOnly),
            @"Overlay-only composition preserves source-over pixels");
        CGImageRef plain = MTIconCompositeCreateImage(source, NULL, NULL);
        MTCompositorCheck(MTCompositorImagesEqual(source, plain),
            @"No decorations preserve the source pixels");
        CGImageRelease(plain);
        CGImageRelease(oldOverlay);
        CGImageRelease(overlayOnly);
        CGImageRelease(maskOnly);
        CGImageRelease(fused);
        CGImageRelease(reference);
        CGImageRelease(masked);
        CGImageRelease(overlay);
        CGImageRelease(mask);
        CGImageRelease(source);
    }
    CGImageRef source = MTCompositorFixture(60, 60, 1, YES);
    CGImageRef wrong = MTCompositorFixture(59, 60, 2, NO);
    MTCompositorCheck(MTIconCompositeCreateImage(NULL, NULL, NULL) == NULL,
        @"Missing sources fail closed");
    MTCompositorCheck(MTIconCompositeCreateImage(source, wrong, NULL) == NULL &&
        MTIconCompositeCreateImage(source, NULL, wrong) == NULL,
        @"Mismatched layer dimensions cannot escape the raster contract");
    MTCompositorCheck(MTIconMaskCreateImage(source, NULL) == NULL &&
        MTIconOverlayCreateImage(source, NULL) == NULL,
        @"Legacy single-layer entry points retain their missing-layer contract");
    CGImageRelease(wrong);
    CGImageRelease(source);
    return MTCompositorAssertions;
}

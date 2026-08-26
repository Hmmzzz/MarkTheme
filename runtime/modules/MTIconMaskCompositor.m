#import "MTIconMaskCompositor.h"

#include <stdint.h>

static const size_t MTIconMaskMaximumDimension = 4096;
static const size_t MTIconMaskMaximumPixelCount = 16 * 1024 * 1024;

BOOL MTIconMaskHasTransparentCornerPixels(CGImageRef maskImage) {
    size_t width = maskImage == NULL ? 0 : CGImageGetWidth(maskImage);
    size_t height = maskImage == NULL ? 0 : CGImageGetHeight(maskImage);
    if (width == 0 || height == 0) {
        return NO;
    }
    uint8_t pixels[16] = {0};
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = colorSpace == NULL ? NULL :
        CGBitmapContextCreate(pixels, 2, 2, 8, 8, colorSpace,
            kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    if (colorSpace != NULL) CGColorSpaceRelease(colorSpace);
    if (context == NULL) return NO;
    CGContextSetBlendMode(context, kCGBlendModeCopy);
    CGContextSetInterpolationQuality(context, kCGInterpolationNone);
    CGContextSetShouldAntialias(context, false);
    CGRect sourceCorners[4] = {
        CGRectMake(0, 0, 1, 1),
        CGRectMake(width - 1, 0, 1, 1),
        CGRectMake(0, height - 1, 1, 1),
        CGRectMake(width - 1, height - 1, 1, 1),
    };
    CGRect destinationCorners[4] = {
        CGRectMake(0, 0, 1, 1),
        CGRectMake(1, 0, 1, 1),
        CGRectMake(0, 1, 1, 1),
        CGRectMake(1, 1, 1, 1),
    };
    for (NSUInteger index = 0; index < 4; index++) {
        CGImageRef corner = CGImageCreateWithImageInRect(
            maskImage, sourceCorners[index]);
        if (corner == NULL) {
            CGContextRelease(context);
            return NO;
        }
        CGContextDrawImage(context, destinationCorners[index], corner);
        CGImageRelease(corner);
    }
    CGContextRelease(context);
    return pixels[3] == 0 && pixels[7] == 0 &&
        pixels[11] == 0 && pixels[15] == 0;
}

// Both compositors share one exact same-size contract and one bounded RGBA
// context; only the blend mode of the second draw differs.
static CGContextRef MTIconCompositorCreateContext(CGImageRef sourceImage,
                                                  CGImageRef appliedImage,
                                                  CGRect *bounds) {
    if (sourceImage == NULL || appliedImage == NULL) return NULL;
    size_t width = CGImageGetWidth(sourceImage);
    size_t height = CGImageGetHeight(sourceImage);
    if (width == 0 || height == 0 ||
        width != CGImageGetWidth(appliedImage) ||
        height != CGImageGetHeight(appliedImage) ||
        width > MTIconMaskMaximumDimension ||
        height > MTIconMaskMaximumDimension ||
        width > MTIconMaskMaximumPixelCount / height ||
        width > SIZE_MAX / 4) {
        return NULL;
    }
    size_t bytesPerRow = width * 4;
    if (height > SIZE_MAX / bytesPerRow) return NULL;

    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    if (colorSpace == NULL) return NULL;
    CGBitmapInfo bitmapInfo =
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big;
    CGContextRef context = CGBitmapContextCreate(
        NULL, width, height, 8, bytesPerRow, colorSpace, bitmapInfo);
    CGColorSpaceRelease(colorSpace);
    if (context == NULL) return NULL;

    *bounds = CGRectMake(0, 0, width, height);
    CGContextSetInterpolationQuality(context, kCGInterpolationNone);
    CGContextSetShouldAntialias(context, false);
    CGContextSetBlendMode(context, kCGBlendModeCopy);
    CGContextDrawImage(context, *bounds, sourceImage);
    return context;
}

CGImageRef MTIconMaskCreateImage(CGImageRef sourceImage,
                                 CGImageRef maskImage) {
    CGRect bounds = CGRectZero;
    CGContextRef context = MTIconCompositorCreateContext(
        sourceImage, maskImage, &bounds);
    if (context == NULL) return NULL;
    CGContextSetBlendMode(context, kCGBlendModeDestinationIn);
    CGContextDrawImage(context, bounds, maskImage);
    CGImageRef result = CGBitmapContextCreateImage(context);
    CGContextRelease(context);
    return result;
}

CGImageRef MTIconOverlayCreateImage(CGImageRef sourceImage,
                                    CGImageRef overlayImage) {
    CGRect bounds = CGRectZero;
    CGContextRef context = MTIconCompositorCreateContext(
        sourceImage, overlayImage, &bounds);
    if (context == NULL) return NULL;
    // Normal source-over keeps the icon's own pixels wherever the overlay is
    // transparent, so authored artwork adds to the icon instead of clipping it.
    CGContextSetBlendMode(context, kCGBlendModeNormal);
    CGContextDrawImage(context, bounds, overlayImage);
    CGImageRef result = CGBitmapContextCreateImage(context);
    CGContextRelease(context);
    return result;
}

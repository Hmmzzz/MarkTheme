#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#include <time.h>
#import "modules/MTIconMaskCompositor.h"

static CGImageRef MTBenchmarkImage(size_t pixels, CGFloat alpha) {
    CGColorSpaceRef color = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(NULL, pixels, pixels, 8,
        pixels * 4, color,
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(color);
    if (context == NULL) return NULL;
    CGContextSetRGBFillColor(context, 0.3, 0.6, 0.9, alpha);
    CGContextFillRect(context, CGRectMake(0, 0, pixels, pixels));
    CGImageRef image = CGBitmapContextCreateImage(context);
    CGContextRelease(context);
    return image;
}
static double MTBenchmarkNow(void) {
    struct timespec time;
    clock_gettime(CLOCK_MONOTONIC_RAW, &time);
    return time.tv_sec + time.tv_nsec / 1e9;
}
static double MTBenchmarkComposition(CGImageRef source, CGImageRef mask,
    CGImageRef overlay, NSUInteger iterations, BOOL fused) {
    double started = MTBenchmarkNow();
    for (NSUInteger i = 0; i < iterations; i++) {
        CGImageRef output = NULL;
        if (fused) {
            output = MTIconCompositeCreateImage(source, mask, overlay);
        } else {
            CGImageRef intermediate = MTIconMaskCreateImage(source, mask);
            output = MTIconOverlayCreateImage(intermediate, overlay);
            CGImageRelease(intermediate);
        }
        if (output == NULL) exit(1);
        // Force materialization equally for both paths before releasing it.
        CFDataRef pixels = CGDataProviderCopyData(CGImageGetDataProvider(output));
        if (pixels == NULL) exit(1);
        CFRelease(pixels);
        CGImageRelease(output);
    }
    return (MTBenchmarkNow() - started) * 1000.0 / iterations;
}
int main(void) {
    @autoreleasepool {
        NSMutableArray *cases = [NSMutableArray array];
        for (NSNumber *dimension in @[@120, @180, @256, @512]) {
            NSUInteger pixels = dimension.unsignedIntegerValue;
            CGImageRef source = MTBenchmarkImage(pixels, 1);
            CGImageRef mask = MTBenchmarkImage(pixels, 0.65);
            CGImageRef overlay = MTBenchmarkImage(pixels, 0.25);
            if (source == NULL || mask == NULL || overlay == NULL) return 1;
            NSMutableArray *separate = [NSMutableArray array];
            NSMutableArray *combined = [NSMutableArray array];
            (void)MTBenchmarkComposition(source, mask, overlay, 20, NO);
            (void)MTBenchmarkComposition(source, mask, overlay, 20, YES);
            for (NSUInteger round = 0; round < 7; round++) {
                for (NSUInteger pass = 0; pass < 2; pass++) {
                    BOOL fused = ((round + pass) % 2) == 0;
                    double duration = MTBenchmarkComposition(source, mask, overlay, 200, fused);
                    [(fused ? combined : separate) addObject:@(duration)];
                }
            }
            [separate sortUsingSelector:@selector(compare:)];
            [combined sortUsingSelector:@selector(compare:)];
            [cases addObject:@{
                @"pixelDimension": dimension,
                @"iterationsPerSample": @200,
                @"samples": @7,
                @"twoPassMedianMillisecondsPerIcon": separate[3],
                @"onePassMedianMillisecondsPerIcon": combined[3],
                @"onePassToTwoPassRatio": @([combined[3] doubleValue] / [separate[3] doubleValue]),
            }];
            CGImageRelease(overlay);
            CGImageRelease(mask);
            CGImageRelease(source);
        }
        NSDictionary *report = @{
            @"benchmark": @"mask-overlay-composition",
            @"scope": @"host microbenchmark; excludes decoding, IO and system icon delivery",
            @"operatingSystem": NSProcessInfo.processInfo.operatingSystemVersionString,
            @"cases": cases,
        };
        NSData *data = [NSJSONSerialization dataWithJSONObject:report
            options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:NULL];
        fwrite(data.bytes, 1, data.length, stdout);
        fputc('\n', stdout);
    }
    return 0;
}

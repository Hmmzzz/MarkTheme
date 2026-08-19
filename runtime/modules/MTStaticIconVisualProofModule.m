#import "MTStaticIconVisualProofModule.h"

#import <UIKit/UIKit.h>
#import <os/lock.h>

#import "MTStaticIconVisualProofContract.h"

NSString *const MTStaticIconVisualProofPatternName =
    @"magenta-cyan-geometric";

MTStaticIconVisualProofObservation
    MTRuntimeStaticIconVisualProofObservation = {
        .schemaVersion = 1,
        .reserved = 0,
        .lookupCalls = ATOMIC_VAR_INIT(0),
        .misses = ATOMIC_VAR_INIT(0),
        .targetHits = ATOMIC_VAR_INIT(0),
        .targetImageResults = ATOMIC_VAR_INIT(0),
        .replacementApplied = ATOMIC_VAR_INIT(0),
        .replacementFallback = ATOMIC_VAR_INIT(0),
        .replacementGenerated = ATOMIC_VAR_INIT(0),
    };

_Static_assert(sizeof(MTStaticIconVisualProofObservation) == 64,
    "The M3-C visual proof observation layout must remain fixed.");

static os_unfair_lock MTReplacementLock = OS_UNFAIR_LOCK_INIT;
static UIImage *MTCachedReplacement;
static CGSize MTCachedReplacementSize;
static CGFloat MTCachedReplacementScale;

static UIImage *MTCreateVisualProofImage(CGSize pointSize, CGFloat scale) {
    UIGraphicsImageRendererFormat *format =
        [[UIGraphicsImageRendererFormat alloc] init];
    format.opaque = YES;
    format.scale = scale;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc]
        initWithSize:pointSize format:format];
    return [renderer imageWithActions:^(
        UIGraphicsImageRendererContext *rendererContext) {
        CGContextRef context = rendererContext.CGContext;
        CGRect bounds = (CGRect){ .origin = CGPointZero, .size = pointSize };
        CGFloat halfWidth = pointSize.width / 2;
        CGFloat halfHeight = pointSize.height / 2;

        CGContextSetRGBFillColor(context, 1.0, 0.08, 0.72, 1.0);
        CGContextFillRect(context, bounds);
        CGContextSetRGBFillColor(context, 0.0, 0.88, 1.0, 1.0);
        CGContextFillRect(context,
            CGRectMake(halfWidth, 0, halfWidth, halfHeight));
        CGContextFillRect(context,
            CGRectMake(0, halfHeight, halfWidth, halfHeight));

        CGFloat ringDiameter = MIN(pointSize.width, pointSize.height) * 0.48;
        CGRect ringRect = CGRectMake(
            (pointSize.width - ringDiameter) / 2,
            (pointSize.height - ringDiameter) / 2,
            ringDiameter, ringDiameter);
        CGContextSetRGBFillColor(context, 1.0, 1.0, 1.0, 1.0);
        CGContextFillEllipseInRect(context, ringRect);

        CGFloat centerDiameter = ringDiameter * 0.54;
        CGRect centerRect = CGRectMake(
            (pointSize.width - centerDiameter) / 2,
            (pointSize.height - centerDiameter) / 2,
            centerDiameter, centerDiameter);
        CGContextSetRGBFillColor(context, 0.04, 0.05, 0.12, 1.0);
        CGContextFillEllipseInRect(context, centerRect);
    }];
}

static UIImage *MTReplacementForOriginalImage(UIImage *originalImage) {
    CGSize pointSize = originalImage.size;
    CGFloat scale = originalImage.scale;
    if (!MTStaticIconVisualProofImageContractIsSupported(pointSize, scale)) {
        return nil;
    }

    os_unfair_lock_lock(&MTReplacementLock);
    UIImage *replacement = MTCachedReplacement;
    BOOL cacheMatches = replacement != nil &&
        CGSizeEqualToSize(MTCachedReplacementSize, pointSize) &&
        MTCachedReplacementScale == scale;
    os_unfair_lock_unlock(&MTReplacementLock);
    return cacheMatches ? replacement : nil;
}

BOOL MTStaticIconVisualProofPrepare(void) {
    if (![NSThread isMainThread]) return NO;

    CGSize pointSize = MTStaticIconVisualProofExpectedPointSize;
    CGFloat scale = MTStaticIconVisualProofExpectedScale;
    if (!MTStaticIconVisualProofImageContractIsSupported(pointSize, scale)) {
        return NO;
    }
    UIImage *replacement = MTCreateVisualProofImage(pointSize, scale);
    if (replacement == nil ||
        !CGSizeEqualToSize(replacement.size, pointSize) ||
        replacement.scale != scale) {
        return NO;
    }

    os_unfair_lock_lock(&MTReplacementLock);
    MTCachedReplacement = replacement;
    MTCachedReplacementSize = pointSize;
    MTCachedReplacementScale = scale;
    atomic_fetch_add_explicit(
        &MTRuntimeStaticIconVisualProofObservation.replacementGenerated,
        1, memory_order_relaxed);
    os_unfair_lock_unlock(&MTReplacementLock);
    return YES;
}

id MTStaticIconVisualProofResolve(NSString *bundleIdentifier,
                                  id originalResult) {
    atomic_fetch_add_explicit(
        &MTRuntimeStaticIconVisualProofObservation.lookupCalls,
        1, memory_order_relaxed);
    if (!MTStaticIconVisualProofMatchesTarget(bundleIdentifier)) {
        atomic_fetch_add_explicit(
            &MTRuntimeStaticIconVisualProofObservation.misses,
            1, memory_order_relaxed);
        return nil;
    }

    atomic_fetch_add_explicit(
        &MTRuntimeStaticIconVisualProofObservation.targetHits,
        1, memory_order_relaxed);
    UIImage *replacement = nil;
    if ([originalResult isKindOfClass:UIImage.class] &&
        MTStaticIconVisualProofImageContractIsSupported(
            ((UIImage *)originalResult).size,
            ((UIImage *)originalResult).scale)) {
        atomic_fetch_add_explicit(
            &MTRuntimeStaticIconVisualProofObservation.targetImageResults,
            1, memory_order_relaxed);
        replacement = MTReplacementForOriginalImage((UIImage *)originalResult);
    }
    if (replacement != nil) {
        atomic_fetch_add_explicit(
            &MTRuntimeStaticIconVisualProofObservation.replacementApplied,
            1, memory_order_relaxed);
    } else {
        atomic_fetch_add_explicit(
            &MTRuntimeStaticIconVisualProofObservation.replacementFallback,
            1, memory_order_relaxed);
    }
    return replacement;
}

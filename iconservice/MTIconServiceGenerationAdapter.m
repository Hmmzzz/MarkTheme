#import "MTIconServiceGenerationAdapter.h"

#import <CydiaSubstrate/CydiaSubstrate.h>

#include <stdatomic.h>

#import "MTIconServiceABI.h"
#import "MTIconServiceImageResolver.h"

NSString *const MTIconServiceGenerationAdapterErrorDomain =
    @"com.hmmzzz.marktheme.icon-service-generation-adapter";

typedef id (*MTIconServiceGenerationFunction)(
    id, SEL, id __autoreleasing *_Nullable);

MTIconServiceGenerationObservation MTIconServiceGenerationAdapterObservation = {
    .schemaVersion = 1,
    .installed = ATOMIC_VAR_INIT(0),
    .calls = ATOMIC_VAR_INIT(0),
    .acceptedRequests = ATOMIC_VAR_INIT(0),
    .resolverHits = ATOMIC_VAR_INIT(0),
    .replacements = ATOMIC_VAR_INIT(0),
    .fallbacks = ATOMIC_VAR_INIT(0),
};

_Static_assert(sizeof(MTIconServiceGenerationObservation) == 48,
    "Icon service generation observation ABI changed");

static MTIconServiceGenerationFunction MTOriginalGeneration;
static MTIconServiceRuntimeMode MTInstalledMode;
static MTIconServiceImageResolver *MTInstalledResolver;

static void MTIconServiceAdapterSetError(NSError **error,
                                         NSInteger code,
                                         NSString *description,
                                         NSError *_Nullable underlying) {
    if (error == NULL) return;
    NSMutableDictionary *userInfo = [@{
        NSLocalizedDescriptionKey : description,
    } mutableCopy];
    if (underlying != nil) userInfo[NSUnderlyingErrorKey] = underlying;
    *error = [NSError errorWithDomain:
        MTIconServiceGenerationAdapterErrorDomain
                                 code:code
                             userInfo:userInfo];
}

static id MTIconServiceHookedGeneration(
    id self,
    SEL selector,
    id __autoreleasing *recordIdentifiersOut) {
    id original = MTOriginalGeneration(
        self, selector, recordIdentifiersOut);
    atomic_fetch_add_explicit(
        &MTIconServiceGenerationAdapterObservation.calls,
        1, memory_order_relaxed);
    if (MTInstalledMode != MTIconServiceRuntimeModeSource ||
        MTInstalledResolver == nil || original == nil) {
        return original;
    }

    @try {
        MTIconServiceRequestContext *context =
            MTIconServiceABIContextForRequest(self, NULL);
        MTIconServiceImageGeometry geometry = {0};
        NSString *stockDigest = MTIconServiceABIImageDigest(original);
        if (context == nil || stockDigest.length == 0 ||
            !MTIconServiceABIReadImageGeometry(original, &geometry) ||
            !MTIconServiceImageGeometryIsSupported(geometry)) {
            atomic_fetch_add_explicit(
                &MTIconServiceGenerationAdapterObservation.fallbacks,
                1, memory_order_relaxed);
            return original;
        }
        atomic_fetch_add_explicit(
            &MTIconServiceGenerationAdapterObservation.acceptedRequests,
            1, memory_order_relaxed);
        CGImageRef stockCGImage =
            MTIconServiceABICopyImageCGImage(original);
        if (stockCGImage == NULL) {
            atomic_fetch_add_explicit(
                &MTIconServiceGenerationAdapterObservation.fallbacks,
                1, memory_order_relaxed);
            return original;
        }
        CGImageRef replacementCGImage = [MTInstalledResolver
            copyReplacementForBundleIdentifier:context.bundleIdentifier
            pointSize:context.pointSize
            scale:context.scale
            pixelWidth:(uint32_t)geometry.pixelSize.width
            pixelHeight:(uint32_t)geometry.pixelSize.height
            stockImageDigest:stockDigest
            stockCGImage:stockCGImage
            error:NULL];
        CGImageRelease(stockCGImage);
        if (replacementCGImage == NULL) {
            atomic_fetch_add_explicit(
                &MTIconServiceGenerationAdapterObservation.fallbacks,
                1, memory_order_relaxed);
            return original;
        }
        atomic_fetch_add_explicit(
            &MTIconServiceGenerationAdapterObservation.resolverHits,
            1, memory_order_relaxed);
        id replacement = MTIconServiceABICreateReplacementImage(
            replacementCGImage, original, NULL);
        CGImageRelease(replacementCGImage);
        if (replacement == nil) {
            atomic_fetch_add_explicit(
                &MTIconServiceGenerationAdapterObservation.fallbacks,
                1, memory_order_relaxed);
            return original;
        }
        atomic_fetch_add_explicit(
            &MTIconServiceGenerationAdapterObservation.replacements,
            1, memory_order_relaxed);
        return replacement;
    } @catch (__unused NSException *exception) {
        atomic_fetch_add_explicit(
            &MTIconServiceGenerationAdapterObservation.fallbacks,
            1, memory_order_relaxed);
        return original;
    }
}

BOOL MTIconServiceGenerationAdapterInstall(
    MTIconServiceRuntimeMode mode,
    MTIconServiceImageResolver *resolver,
    NSError **error) {
    if (error != NULL) *error = nil;
    if (mode != MTIconServiceRuntimeModeObserve &&
        mode != MTIconServiceRuntimeModeSource) {
        MTIconServiceAdapterSetError(error, 1,
            @"Icon service adapter requires observe or source mode.", nil);
        return NO;
    }
    if (mode == MTIconServiceRuntimeModeSource && resolver == nil) {
        MTIconServiceAdapterSetError(error, 2,
            @"Icon service source mode requires an image resolver.", nil);
        return NO;
    }
    uint32_t expected = 0;
    if (!atomic_compare_exchange_strong_explicit(
            &MTIconServiceGenerationAdapterObservation.installed,
            &expected, 1, memory_order_acq_rel, memory_order_acquire)) {
        MTIconServiceAdapterSetError(error, 3,
            @"Icon service adapter is already installed.", nil);
        return NO;
    }
    Method method = NULL;
    NSError *ABIError = nil;
    if (!MTIconServiceABIValidateRuntime(&method, &ABIError) ||
        method == NULL) {
        atomic_store_explicit(
            &MTIconServiceGenerationAdapterObservation.installed,
            0, memory_order_release);
        MTIconServiceAdapterSetError(error, 4,
            @"Icon service ABI rejected adapter installation.", ABIError);
        return NO;
    }
    MTInstalledMode = mode;
    MTInstalledResolver = resolver;
    MTOriginalGeneration = NULL;
    MSHookMessageEx(
        objc_getClass("ISGenerationRequest"), method_getName(method),
        (IMP)MTIconServiceHookedGeneration,
        (IMP *)&MTOriginalGeneration);
    if (MTOriginalGeneration == NULL) {
        MTInstalledResolver = nil;
        MTInstalledMode = MTIconServiceRuntimeModeDisabled;
        atomic_store_explicit(
            &MTIconServiceGenerationAdapterObservation.installed,
            0, memory_order_release);
        MTIconServiceAdapterSetError(error, 5,
            @"Hook backend did not return the original generation IMP.", nil);
        return NO;
    }
    return YES;
}

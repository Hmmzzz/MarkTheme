#import <Foundation/Foundation.h>

#include <stdatomic.h>
#include <stdint.h>

#import "MTIconServiceRuntimeMode.h"

@class MTIconServiceImageResolver;

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const MTIconServiceGenerationAdapterErrorDomain;

typedef struct MTIconServiceGenerationObservation {
    uint32_t schemaVersion;
    _Atomic(uint32_t) installed;
    _Atomic(uint64_t) calls;
    _Atomic(uint64_t) acceptedRequests;
    _Atomic(uint64_t) resolverHits;
    _Atomic(uint64_t) replacements;
    _Atomic(uint64_t) fallbacks;
} MTIconServiceGenerationObservation;

FOUNDATION_EXPORT MTIconServiceGenerationObservation
    MTIconServiceGenerationAdapterObservation;

FOUNDATION_EXPORT BOOL MTIconServiceGenerationAdapterInstall(
    MTIconServiceRuntimeMode mode,
    MTIconServiceImageResolver *_Nullable resolver,
    NSError **error);

NS_ASSUME_NONNULL_END

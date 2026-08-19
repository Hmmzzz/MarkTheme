#import <Foundation/Foundation.h>

#include <stdatomic.h>
#include <stdint.h>

#import "MTRuntimeReplacement.h"

NS_ASSUME_NONNULL_BEGIN

typedef struct MTStaticIconVisualProofObservation {
    uint32_t schemaVersion;
    uint32_t reserved;
    _Atomic(uint64_t) lookupCalls;
    _Atomic(uint64_t) misses;
    _Atomic(uint64_t) targetHits;
    _Atomic(uint64_t) targetImageResults;
    _Atomic(uint64_t) replacementApplied;
    _Atomic(uint64_t) replacementFallback;
    _Atomic(uint64_t) replacementGenerated;
} MTStaticIconVisualProofObservation;

FOUNDATION_EXPORT MTStaticIconVisualProofObservation
    MTRuntimeStaticIconVisualProofObservation;
FOUNDATION_EXPORT NSString *const MTStaticIconVisualProofPatternName;

// Creates the one build-pinned image before the ProcessAdapter installs its
// Hook. Runtime resolution never performs UIKit rendering.
FOUNDATION_EXPORT BOOL MTStaticIconVisualProofPrepare(void);

// Returns nil for a non-target or unsupported original result. The Process
// Adapter owns stock fallback and therefore never needs UIKit knowledge.
FOUNDATION_EXPORT id _Nullable MTStaticIconVisualProofResolve(
    NSString *bundleIdentifier,
    id _Nullable originalResult);

NS_ASSUME_NONNULL_END

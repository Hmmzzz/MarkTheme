#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <dispatch/dispatch.h>

#include <stdatomic.h>
#include <stdint.h>

@class MTRuntimeKernel;

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const MTStaticIconSnapshotModuleID;
FOUNDATION_EXPORT NSString *const MTStaticIconSnapshotModuleErrorDomain;

typedef NS_ENUM(uint32_t, MTStaticIconSnapshotModuleState) {
    MTStaticIconSnapshotModuleStateDormant = 0,
    MTStaticIconSnapshotModuleStateConfigured = 1,
    MTStaticIconSnapshotModuleStatePrepared = 2,
};

typedef struct MTStaticIconSnapshotObservation {
    uint32_t schemaVersion;
    _Atomic(uint32_t) state;
    _Atomic(uint64_t) lookupCalls;
    _Atomic(uint64_t) unsupportedOriginalMisses;
    _Atomic(uint64_t) snapshotMisses;
    _Atomic(uint64_t) resourceHits;
    _Atomic(uint64_t) cacheHits;
    _Atomic(uint64_t) decodeScheduled;
    _Atomic(uint64_t) pendingMisses;
    _Atomic(uint64_t) failureMisses;
    _Atomic(uint64_t) saturatedMisses;
    _Atomic(uint64_t) decodeSuccesses;
    _Atomic(uint64_t) decodeFailures;
    _Atomic(uint64_t) staleCompletions;
    _Atomic(uint64_t) memoryPressurePurges;
    _Atomic(uint64_t) cacheEvictions;
} MTStaticIconSnapshotObservation;

FOUNDATION_EXPORT MTStaticIconSnapshotObservation
    MTRuntimeStaticIconSnapshotObservation;

// Configures one process-local module against the already-created Kernel.
// Preparation runs on the Adapter's guarded main-queue install path.
FOUNDATION_EXPORT BOOL MTStaticIconSnapshotConfigure(
    MTRuntimeKernel *kernel,
    BOOL calendarCompositeEnabled,
    NSError **error);
FOUNDATION_EXPORT BOOL MTStaticIconSnapshotPrepare(void);
FOUNDATION_EXPORT void MTStaticIconSnapshotReload(void);

// Dynamic Calendar/Clock consumers resolve on demand against the immutable
// Generation and reuse the same bounded cache.
FOUNDATION_EXPORT id _Nullable MTStaticIconSnapshotResolve(
    NSString *bundleIdentifier,
    id _Nullable originalResult);

// Resolves one exact square application-icon contract supplied by a proven
// system producer such as SearchUI. Unlike the UIImage-shaped convenience
// entry above, this does not infer scale from a potentially rewrapped stock
// carrier.
FOUNDATION_EXPORT id _Nullable MTStaticIconSnapshotResolveSystemSurface(
    NSString *bundleIdentifier,
    CGSize pointSize,
    CGFloat scale);

NS_ASSUME_NONNULL_END

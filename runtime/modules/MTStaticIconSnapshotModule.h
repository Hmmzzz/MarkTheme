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

// The dynamic Clock consumer resolves its face against the immutable
// Generation and reuses the same bounded cache.
FOUNDATION_EXPORT id _Nullable MTStaticIconSnapshotResolve(
    NSString *bundleIdentifier,
    id _Nullable originalResult);

// CalendarUIKit supplies the exact date components and calendar used by its
// native dynamic generator. Resolve the themed raw source against that same
// semantic input instead of recomputing "today" in a display-layer adapter.
FOUNDATION_EXPORT CGImageRef _Nullable
MTStaticIconSnapshotResolveCalendarSource(
    NSDateComponents *dateComponents,
    NSCalendar *calendar,
    NSInteger format,
    CGSize pointSize,
    CGFloat scale) CF_RETURNS_RETAINED;

NS_ASSUME_NONNULL_END

#import <Foundation/Foundation.h>

#include <stdatomic.h>
#include <stdint.h>

@class MTRuntimeKernel;

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const MTDialerSnapshotModuleID;

typedef NS_ENUM(uint32_t, MTDialerSnapshotModuleState) {
    MTDialerSnapshotModuleStateDormant = 0,
    MTDialerSnapshotModuleStateConfigured = 1,
    MTDialerSnapshotModuleStateReady = 2,
};

typedef struct MTDialerSnapshotObservation {
    uint32_t schemaVersion;
    _Atomic(uint32_t) state;
    _Atomic(uint64_t) reloads;
    _Atomic(uint64_t) contextRequests;
    _Atomic(uint64_t) contextMisses;
    _Atomic(uint64_t) resourceHits;
    _Atomic(uint64_t) decodeSuccesses;
    _Atomic(uint64_t) decodeFailures;
    _Atomic(uint64_t) imageSetsReady;
    _Atomic(uint64_t) overlaysCreated;
    _Atomic(uint64_t) overlaysUpdated;
    _Atomic(uint64_t) overlaysRemoved;
} MTDialerSnapshotObservation;

FOUNDATION_EXPORT MTDialerSnapshotObservation
    MTRuntimeDialerSnapshotObservation;

FOUNDATION_EXPORT BOOL MTDialerSnapshotConfigure(
    MTRuntimeKernel *kernel,
    NSError **error);
// Called from the deterministic main-queue Adapter installation boundary.
// It starts bounded background preparation but never waits for it.
FOUNDATION_EXPORT BOOL MTDialerSnapshotPrepare(void);
FOUNDATION_EXPORT void MTDialerSnapshotReload(void);
FOUNDATION_EXPORT void MTDialerSnapshotSetReadyHandler(
    dispatch_block_t _Nullable handler);

// Applies one full-button theme image above the stock hierarchy. A miss or an
// unready image set removes any previous overlay and therefore restores stock.
FOUNDATION_EXPORT BOOL MTDialerSnapshotResolveButton(
    id button,
    NSString *normalSubject,
    NSString *highlightedSubject,
    BOOL highlighted);

NS_ASSUME_NONNULL_END

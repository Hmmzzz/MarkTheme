#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>

#import "MTStatusBarContract.h"

#include <stdatomic.h>
#include <stdint.h>

@class MTRuntimeKernel;

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const MTStatusBarSnapshotModuleID;

typedef NS_ENUM(uint32_t, MTStatusBarSnapshotModuleState) {
    MTStatusBarSnapshotModuleStateDormant = 0,
    MTStatusBarSnapshotModuleStateConfigured = 1,
    MTStatusBarSnapshotModuleStateReady = 2,
};

typedef struct MTStatusBarSnapshotObservation {
    uint32_t schemaVersion;
    _Atomic(uint32_t) state;
    _Atomic(uint64_t) reloads;
    _Atomic(uint64_t) contextRequests;
    _Atomic(uint64_t) contextMisses;
    _Atomic(uint64_t) resourceHits;
    _Atomic(uint64_t) decodeSuccesses;
    _Atomic(uint64_t) decodeFailures;
    _Atomic(uint64_t) imageSetsReady;
    _Atomic(uint64_t) imageResolutions;
    _Atomic(uint64_t) replacementResults;
} MTStatusBarSnapshotObservation;

FOUNDATION_EXPORT MTStatusBarSnapshotObservation
    MTRuntimeStatusBarSnapshotObservation;

FOUNDATION_EXPORT BOOL MTStatusBarSnapshotConfigure(
    MTRuntimeKernel *kernel,
    NSError **error);
FOUNDATION_EXPORT void MTStatusBarSnapshotReload(void);
FOUNDATION_EXPORT void MTStatusBarSnapshotSetReadyHandler(
    dispatch_block_t _Nullable handler);

// Called only from a real status-bar view boundary on the main thread. The
// ModuleRuntime owns the overlay and exact stock restoration; a miss returns NO.
FOUNDATION_EXPORT BOOL MTStatusBarSnapshotResolveSignalView(
    id signalView,
    id _Nullable activeColor,
    MTStatusBarSignalKind kind,
    NSInteger level);

NS_ASSUME_NONNULL_END

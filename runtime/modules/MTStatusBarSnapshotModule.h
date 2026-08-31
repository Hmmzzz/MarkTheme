#import <Foundation/Foundation.h>
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
    _Atomic(uint64_t) nativeCommitRequests;
    _Atomic(uint64_t) contextRequests;
    _Atomic(uint64_t) contextMisses;
    _Atomic(uint64_t) resourceHits;
    _Atomic(uint64_t) cacheHits;
    _Atomic(uint64_t) decodeSuccesses;
    _Atomic(uint64_t) decodeFailures;
    _Atomic(uint64_t) replacementResults;
    _Atomic(uint64_t) stockRestores;
} MTStatusBarSnapshotObservation;

FOUNDATION_EXPORT MTStatusBarSnapshotObservation
    MTRuntimeStatusBarSnapshotObservation;

FOUNDATION_EXPORT BOOL MTStatusBarSnapshotConfigure(
    MTRuntimeKernel *kernel,
    NSError **error);

// Called only after SystemStatusUI commits the native active-bar state. The
// ModuleRuntime reuses the existing root-layer contents slot, preserves every
// native child layer, and restores Apple's current state on a resource miss.
FOUNDATION_EXPORT BOOL MTStatusBarSnapshotResolveSignalView(
    id signalView,
    id _Nullable activeColor,
    MTStatusBarSignalKind kind,
    NSInteger level);

NS_ASSUME_NONNULL_END

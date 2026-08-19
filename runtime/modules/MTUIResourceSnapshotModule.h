#import <Foundation/Foundation.h>

#include <stdatomic.h>
#include <stdint.h>

@class MTRuntimeKernel;

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const MTUIResourceSnapshotModuleID;
FOUNDATION_EXPORT NSString *const MTUIResourceSnapshotModuleErrorDomain;

typedef NS_ENUM(uint32_t, MTUIResourceSnapshotModuleState) {
    MTUIResourceSnapshotModuleStateDormant = 0,
    MTUIResourceSnapshotModuleStateConfigured = 1,
    MTUIResourceSnapshotModuleStatePrepared = 2,
};

typedef struct MTUIResourceSnapshotObservation {
    uint32_t schemaVersion;
    _Atomic(uint32_t) state;
    _Atomic(uint64_t) lookupCalls;
    _Atomic(uint64_t) snapshotMisses;
    _Atomic(uint64_t) resourceHits;
    _Atomic(uint64_t) cacheHits;
    _Atomic(uint64_t) decodeSuccesses;
    _Atomic(uint64_t) decodeFailures;
    _Atomic(uint64_t) replacementResults;
    _Atomic(uint64_t) memoryPressurePurges;
} MTUIResourceSnapshotObservation;

FOUNDATION_EXPORT MTUIResourceSnapshotObservation
    MTRuntimeUIResourceSnapshotObservation;

FOUNDATION_EXPORT BOOL MTUIResourceSnapshotConfigure(
    MTRuntimeKernel *kernel,
    NSError **error);
FOUNDATION_EXPORT BOOL MTUIResourceSnapshotPrepare(void);
FOUNDATION_EXPORT id _Nullable MTUIResourceSnapshotResolve(
    NSString *resourceName,
    id _Nullable originalResult);
FOUNDATION_EXPORT id _Nullable MTUIResourceSnapshotResolveShareActivity(
    NSString *activityName,
    id _Nullable originalResult);
FOUNDATION_EXPORT void MTUIResourceSnapshotReload(void);
FOUNDATION_EXPORT NSArray<id> *
    MTUIResourceSnapshotAttachedViewControllers(void);

NS_ASSUME_NONNULL_END

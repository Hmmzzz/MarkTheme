#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>

#include <stdatomic.h>
#include <stdint.h>

@class MTRuntimeKernel;

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const MTBadgeSnapshotModuleID;

typedef NS_ENUM(uint32_t, MTBadgeSnapshotModuleState) {
    MTBadgeSnapshotModuleStateDormant = 0,
    MTBadgeSnapshotModuleStateConfigured = 1,
    MTBadgeSnapshotModuleStateReady = 2,
};

typedef struct MTBadgeSnapshotObservation {
    uint32_t schemaVersion;
    _Atomic(uint32_t) state;
    _Atomic(uint64_t) reloads;
    _Atomic(uint64_t) lightResourceHits;
    _Atomic(uint64_t) darkResourceHits;
    _Atomic(uint64_t) decodeSuccesses;
    _Atomic(uint64_t) decodeFailures;
    _Atomic(uint64_t) imageResolutions;
    _Atomic(uint64_t) replacementResults;
    _Atomic(uint64_t) originalImagesRestored;
    _Atomic(uint64_t) forgottenViews;
} MTBadgeSnapshotObservation;

FOUNDATION_EXPORT MTBadgeSnapshotObservation
    MTRuntimeBadgeSnapshotObservation;

FOUNDATION_EXPORT BOOL MTBadgeSnapshotConfigure(
    MTRuntimeKernel *kernel,
    NSError **error);
FOUNDATION_EXPORT void MTBadgeSnapshotReload(void);
FOUNDATION_EXPORT void MTBadgeSnapshotSetReadyHandler(
    dispatch_block_t _Nullable handler);

// The ProcessAdapter owns the exact private ivar/method ABI. ModuleRuntime
// receives opaque UIKit objects, tracks the stock image weakly, and returns
// either the exact input or one immutable appearance-aware replacement.
FOUNDATION_EXPORT id _Nullable MTBadgeSnapshotResolveBackgroundImage(
    id badgeView,
    id backgroundView,
    id _Nullable originalImage,
    BOOL *didReplace);
FOUNDATION_EXPORT void MTBadgeSnapshotForgetBadgeView(
    id badgeView,
    id _Nullable backgroundView);

NS_ASSUME_NONNULL_END
